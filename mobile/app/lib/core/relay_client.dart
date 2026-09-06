/// Device-side client for the opaque relay port tunnel.
///
/// Optional end-to-end privacy with the bridge (`e2eSecret` + `hostId`):
/// stream payloads are sealed/compressed per `e2e_codec.dart` and small TCP
/// reads are coalesced, then aggregated across streams into `stream-batch`
/// frames. The bridge announces E2E by injecting a HELLO record as the first
/// payload of every stream; peers without the secret (or a legacy bridge)
/// keep the exact legacy frame-per-read behavior.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'e2e_codec.dart';
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
    this.e2eSecret,
    this.hostId = '',
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

  /// Base64url shared secret from the pairing QR (`e2e=`); enables the E2E
  /// record layer when the bridge announces itself with a HELLO record.
  final String? e2eSecret;
  final String hostId;

  final StreamChannel<dynamic> Function(Uri uri, {Map<String, dynamic>? headers})
  _connector;

  StreamChannel<dynamic>? _channel;
  final Map<String, _StreamState> _streams = {};
  int _seq = 0;
  bool _closing = false;
  void Function(bool online)? onStatus;
  void Function(String message)? onFatal;

  /// Serializes E2E seal/open so per-direction counters stay ordered.
  Future<void> _rxChain = Future.value();
  Future<void> _txChain = Future.value();

  E2eCodec? _codec;
  final List<Map<String, String>> _batchQueue = [];
  Timer? _batchTimer;

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
    if (e2eSecret != null && e2eSecret!.isNotEmpty) {
      _codec = E2eCodec(secret: e2eSecret!, hostId: hostId);
    }
  }

  void _disconnect(String reason) {
    _channel = null;
    onStatus?.call(false);
    for (final stream in _streams.values) {
      stream.cancelTimer();
      if (!stream.isClosed) stream.close();
    }
    _streams.clear();
    onFatal?.call(reason);
  }

  void close() {
    _closing = true;
    _batchTimer?.cancel();
    _batchTimer = null;
    for (final id in _streams.keys.toList()) {
      _streams[id]?.cancelTimer();
      _closeStream(id, 'client-closed');
    }
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
          _inbound(id, base64Decode(data));
        }
        break;
      case 'stream-batch':
        final items = (frame['items'] as List?) ?? const [];
        for (final item in items) {
          final map = (item as Map).cast<String, dynamic>();
          final id = map['id'] as String?;
          final data = map['d'] as String?;
          if (id != null && data != null) {
            _inbound(id, base64Decode(data));
          }
        }
        break;
      case 'stream-close':
        final id = frame['streamId'] as String?;
        if (id != null) {
          final state = _streams.remove(id);
          if (state != null) {
            if (!state.isClosed) state.close();
          }
        }
        break;
    }
  }

  /// Bridge → WebView direction: unwrap records per stream state and feed
  /// plaintext to the local stream. Serialized to keep decode order stable.
  void _inbound(String id, Uint8List payload) {
    final state = _streams[id];
    if (state == null || state.isClosed) return;
    final codec = _codec;
    if (codec == null) {
      state.deliver(payload);
      return;
    }
    _rxChain = _rxChain.then((_) async {
      if (state.isClosed) return;
      try {
        final record = await codec.open(dirBridgeToDevice, payload);
        if (record == null) {
          if (state.mode == _StreamMode.enc) {
            _closeStream(id, 'e2e-broken');
          } else {
            state.deliver(payload);
          }
          return;
        }
        if (record.isHello) {
          // Bridge announced E2E: answer exactly once (pending -> enc), so
          // it learns we understand E2E + batching without a HELLO loop.
          if (state.mode == _StreamMode.pending) {
            state.mode = _StreamMode.enc;
            final hello = await codec.hello(dirDeviceToBridge);
            _queueSealed(state, hello);
          }
          return;
        }
        state.deliver(record.body);
      } on E2eBrokenException {
        _closeStream(id, 'e2e-broken');
      }
    });
  }

  /// WebView → bridge direction: coalesce small writes, seal and aggregate.
  void _upstream(_StreamState state, Uint8List bytes) {
    final codec = _codec;
    if (codec == null) {
      _send({
        'v': 1,
        'type': 'stream-data',
        'streamId': state.id,
        'data': base64Encode(bytes),
      });
      return;
    }
    if (state.mode != _StreamMode.enc) {
      // Not negotiated yet: keep plaintext until the bridge's HELLO arrives.
      _send({
        'v': 1,
        'type': 'stream-data',
        'streamId': state.id,
        'data': base64Encode(bytes),
      });
      return;
    }
    state.pending.add(bytes);
    state.pendingBytes += bytes.length;
    if (state.pendingBytes >= _flushBytes) {
      state.flushNow();
      return;
    }
    state.flushTimer ??= Timer(const Duration(milliseconds: 4), () {
      state.flushTimer = null;
      state.flushNow();
    });
  }

  void _queueSealed(_StreamState state, Uint8List record) {
    _batchQueue.add({'id': state.id, 'd': base64Encode(record)});
    _maybeFlushBatch();
  }

  void _sealAndQueue(_StreamState state) {
    if (state.pending.isEmpty) return;
    final blob = BytesBuilder();
    for (final chunk in state.pending) {
      blob.add(chunk);
    }
    state.pending.clear();
    state.pendingBytes = 0;
    final codec = _codec!;
    final body = blob.toBytes();
    _txChain = _txChain.then((_) async {
      final record = await codec.seal(dirDeviceToBridge, body);
      _batchQueue.add({'id': state.id, 'd': base64Encode(record)});
      _maybeFlushBatch();
    });
  }

  void _maybeFlushBatch() {
    if (_batchQueue.isEmpty) return;
    if (_batchQueue.length >= 24) {
      _flushBatch();
      return;
    }
    final oversized = _batchQueue.any((i) => (i['d']!.length) >= _flushBytes);
    if (oversized) {
      _flushBatch();
      return;
    }
    _batchTimer ??= Timer(const Duration(milliseconds: 3), _flushBatch);
  }

  void _flushBatch() {
    _batchTimer?.cancel();
    _batchTimer = null;
    if (_batchQueue.isEmpty) return;
    if (_batchQueue.length == 1) {
      final one = _batchQueue.removeAt(0);
      _send({
        'v': 1,
        'type': 'stream-data',
        'streamId': one['id'],
        'data': one['d'],
      });
      return;
    }
    _send({'v': 1, 'type': 'stream-batch', 'items': _batchQueue});
    _batchQueue.clear();
  }

  void _closeStream(String id, String reason) {
    _streams.remove(id)?.close();
    _send({'v': 1, 'type': 'stream-close', 'streamId': id, 'reason': reason});
  }

  @override
  Future<PortConnection> connectPort(int port) async {
    if (_channel == null) throw RelayError('transport', 'relay is offline');
    final id = _nextId();
    final state = _StreamState(
      id,
      (sid) => _closeStream(sid, 'client-closed'),
      _upstream,
      _sealAndQueue,
    );
    _streams[id] = state;
    print('[rc] stream-open $id port=$port');
    _send({'v': 1, 'type': 'stream-open', 'streamId': id, 'port': port});
    return state.connection;
  }

  static const int _flushBytes = 48 * 1024;
}

enum _StreamMode { pending, enc }

/// Per-stream state: the input the WebProxy reads, pending upstream bytes and
/// the negotiated E2E mode.
class _StreamState implements PortConnection {
  _StreamState(this.id, this._close, this._coalesce, this._flush);

  final String id;
  final void Function(String id) _close;
  final void Function(_StreamState state, Uint8List bytes) _coalesce;
  final void Function(_StreamState state) _flush;

  final StreamController<List<int>> _input = StreamController<List<int>>();
  final List<Uint8List> pending = [];
  int pendingBytes = 0;
  Timer? flushTimer;
  _StreamMode mode = _StreamMode.pending;
  bool _closed = false;

  bool get isClosed => _closed;

  @override
  Stream<List<int>> get input => _input.stream;

  PortConnection get connection => this;

  void deliver(Uint8List bytes) {
    if (!_closed) _input.add(bytes);
  }

  void flushNow() {
    flushTimer?.cancel();
    flushTimer = null;
    if (pending.isEmpty) return;
    _flush(this);
  }

  void cancelTimer() {
    flushTimer?.cancel();
    flushTimer = null;
  }

  @override
  void add(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    _coalesce(this, Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancelTimer();
    await _input.close();
    _close(id);
  }
}

