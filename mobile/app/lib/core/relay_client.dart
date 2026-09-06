/// Device-side client for the opaque relay port tunnel.
library;

import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'tunnel_backend.dart';

class RelayError implements Exception {
  final String code;
  final String? message;
  RelayError(this.code, [this.message]);
  @override
  String toString() =>
      'RelayError($code${message == null ? '' : ': $message'})';
}

class RelayClient implements PortBackend {
  RelayClient({
    required this.relayBase,
    required this.sessionToken,
    StreamChannel<dynamic> Function(Uri uri, {Map<String, dynamic>? headers})?
    connector,
  }) : _connector = connector ?? _defaultConnector;

  static StreamChannel<dynamic> _defaultConnector(
    Uri uri, {
    Map<String, dynamic>? headers,
  }) => IOWebSocketChannel.connect(
    uri,
    headers: headers,
    connectTimeout: const Duration(seconds: 8),
  );

  final String relayBase;
  final String sessionToken;
  final StreamChannel<dynamic> Function(
    Uri uri, {
    Map<String, dynamic>? headers,
  })
  _connector;

  StreamChannel<dynamic>? _channel;
  final Map<String, StreamController<List<int>>> _streams = {};
  int _seq = 0;
  bool _closing = false;
  void Function(bool online)? onStatus;
  void Function(String message)? onFatal;

  bool get isConnected => _channel != null;
  String _nextId() =>
      'stream_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  Uri get _wsUri {
    final ws = relayBase.startsWith('https')
        ? relayBase.replaceFirst('https', 'wss')
        : relayBase.replaceFirst('http', 'ws');
    return Uri.parse('$ws/relay/v1/device');
  }

  Future<void> connect() async {
    _closing = false;
    final channel = _connector(
      _wsUri,
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    _channel = channel;
    final ready = Completer<void>();
    channel.stream.listen(
      (raw) {
        if (!ready.isCompleted) ready.complete();
        _onMessage(raw);
      },
      onError: (Object e) {
        if (!ready.isCompleted) {
          ready.completeError(
            RelayError(
              '$e'.contains('401') ? 'unauthorized' : 'transport',
              '$e',
            ),
          );
        }
        if (!_closing) _disconnect('error: $e');
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(RelayError('closed', 'relay closed connection'));
        }
        if (!_closing) _disconnect('closed');
      },
    );
    _send({'v': 1, 'type': 'ping'});
    await Future.any([
      ready.future,
      Future<void>.delayed(const Duration(milliseconds: 600)),
    ]);
  }

  void _disconnect(String reason) {
    _channel = null;
    onStatus?.call(false);
    for (final stream in _streams.values) {
      if (!stream.isClosed) stream.close();
    }
    _streams.clear();
    onFatal?.call(reason);
  }

  void close() {
    _closing = true;
    for (final id in _streams.keys.toList()) _closeStream(id, 'client-closed');
    _channel?.sink.close();
    _channel = null;
  }

  void _send(Map<String, dynamic> frame) =>
      _channel?.sink.add(jsonEncode(frame));

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> frame;
    try {
      frame = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (frame['type']) {
      case 'ping':
        _send({'v': 1, 'type': 'pong'});
        break;
      case 'stream-data':
        final id = frame['streamId'] as String?;
        final data = frame['data'] as String?;
        if (id != null && data != null) {
          _streams[id]?.add(base64Decode(data));
        }
        break;
      case 'stream-close':
        final id = frame['streamId'] as String?;
        if (id != null) {
          final stream = _streams.remove(id);
          if (stream != null && !stream.isClosed) stream.close();
        }
        break;
    }
  }

  @override
  Future<PortConnection> connectPort(int port) async {
    if (_channel == null) throw RelayError('transport', 'relay is offline');
    final id = _nextId();
    final input = StreamController<List<int>>();
    _streams[id] = input;
    _send({'v': 1, 'type': 'stream-open', 'streamId': id, 'port': port});
    return _RelayPortConnection(
      input.stream,
      (bytes) => _send({
        'v': 1,
        'type': 'stream-data',
        'streamId': id,
        'data': base64Encode(bytes),
      }),
      () async {
        _closeStream(id, 'client-closed');
      },
    );
  }

  void _closeStream(String id, String reason) {
    _streams.remove(id)?.close();
    _send({'v': 1, 'type': 'stream-close', 'streamId': id, 'reason': reason});
  }
}

class _RelayPortConnection implements PortConnection {
  _RelayPortConnection(this.input, this._write, this._close);
  @override
  final Stream<List<int>> input;
  final void Function(List<int>) _write;
  final Future<void> Function() _close;
  bool _closed = false;

  @override
  void add(List<int> bytes) {
    if (!_closed && bytes.isNotEmpty) _write(bytes);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _close();
  }
}
