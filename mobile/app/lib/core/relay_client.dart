/// Relay protocol client (device side).
///
/// Speaks the tunnel protocol from docs/mobile-relay-protocol.md over WSS:
///   rpc / rpc-reply / sse-open / sse-frame / sse-close / respond / ping / pong
/// The bridge translates payloads to the dsh web wire format, so this client
/// only ever sees business payloads and dsh server-request frames.
library;

import 'dart:async';
import 'dart:convert';

import 'tunnel_backend.dart';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/io.dart';

import 'dsh_types.dart';

class RelayError implements Exception {
  final String code;
  final String? message;
  RelayError(this.code, [this.message]);
  @override
  String toString() => 'RelayError($code${message == null ? '' : ': $message'})';
}

class RelayClient implements TunnelBackend {
  RelayClient({
    required this.relayBase,
    required this.sessionToken,
    StreamChannel<dynamic> Function(Uri uri, {Map<String, dynamic>? headers})?
        connector,
  }) : _connector = connector ?? _defaultConnector;

  static StreamChannel<dynamic> _defaultConnector(
          Uri uri, {Map<String, dynamic>? headers}) =>
      IOWebSocketChannel.connect(
        uri,
        headers: headers,
        // Without an explicit connect timeout the underlying HttpClient can
        // hang for 30s+ on an unreachable relay (TCP/DNS), while connect()
        // below optimistically returns after 600ms — the app would enter the
        // remote view with a dead tunnel. Bound the handshake instead.
        connectTimeout: const Duration(seconds: 8),
      );

  /// Origin (https://relay.deepvisus.top); wss:// is derived.
  final String relayBase;
  final String sessionToken;
  final StreamChannel<dynamic> Function(Uri uri, {Map<String, dynamic>? headers})
      _connector;

  StreamChannel<dynamic>? _channel;
  int _seq = 0;
  bool _closing = false;

  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, void Function(SseFrame)> _sseHandlers = {};
  final Map<String, void Function(String reason)> _sseClosers = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingHttp = {};
  final Map<String, _HttpTransfer> _httpTransfers = {};
  final Map<String, void Function(String data)> _rawSseHandlers = {};

  /// Fired with true when the tunnel is up, false when the socket drops.
  void Function(bool online)? onStatus;
  /// Fired with a human-readable fatal error (auth failure etc).
  void Function(String message)? onFatal;

  bool get isConnected => _channel != null;

  String _nextId(String prefix) => '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';

  Uri get _wsUri {
    final ws = relayBase.startsWith('https')
        ? relayBase.replaceFirst('https', 'wss')
        : relayBase.replaceFirst('http', 'ws');
    return Uri.parse('$ws/relay/v1/device');
  }

  /// Completes on the first server frame; errors when the relay rejects or
  /// closes the connection (e.g. HTTP 401 on a dead token).
  Completer<void>? _ready;

  Future<void> connect() async {
    _closing = false;
    final channel = _connector(_wsUri, headers: {'Authorization': 'Bearer $sessionToken'});
    _channel = channel;
    final ready = Completer<void>();
    _ready = ready;
    channel.stream.listen(
      _onMessage,
      onError: (Object e) {
        final msg = '$e';
        final code = msg.contains('401') ? 'unauthorized' : 'transport';
        if (!ready.isCompleted) {
          ready.completeError(RelayError(code, 'relay connection failed: $e'));
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
    // The relay answers the ping below immediately, so the tunnel is usually
    // confirmed within one round trip; the silent window is only the fallback.
    _send({'v': 1, 'type': 'ping'});
    await Future.any([
      ready.future,
      Future<void>.delayed(const Duration(milliseconds: 600)),
    ]);
    _ready = null;
  }

  void _disconnect(String reason) {
    _channel = null;
    onStatus?.call(false);
    final err = RelayError('transport', reason);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
    for (final c in _pendingHttp.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pendingHttp.clear();
    for (final t in _httpTransfers.values) {
      t.fail(err);
    }
    _httpTransfers.clear();
  }

  void close() {
    _closing = true;
    _channel?.sink.close();
    _channel = null;
  }

  void _send(Map<String, dynamic> frame) {
    _channel?.sink.add(jsonEncode(frame));
  }

  void _onMessage(dynamic raw) {
    final r = _ready;
    if (r != null && !r.isCompleted) r.complete();
    final Map<String, dynamic> f;
    try {
      f = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (f['type']) {
      case 'pong':
        break;
      case 'ping':
        _send({'v': 1, 'type': 'pong'});
        break;
      case 'rpc-reply':
        final rpcId = f['rpcId'] as String?;
        final body = (f['body'] as Map?)?.cast<String, dynamic>();
        final c = _pending.remove(rpcId);
        if (c != null && !c.isCompleted) c.complete(body ?? const {});
        break;
      case 'sse-frame':
        final ch = f['channel'] as String?;
        final body = (f['body'] as Map?)?.cast<String, dynamic>();
        if (ch != null && body != null) {
          final raw = body['data'] as String?;
          if (raw != null) {
            _rawSseHandlers[ch]?.call(raw);
          } else {
            _sseHandlers[ch]?.call(SseFrame.fromJson(body));
          }
        }
        break;
      case 'sse-close':
        final ch = f['channel'] as String?;
        final reason = ((f['body'] as Map?)?['reason'] as String?) ?? 'closed';
        if (ch != null) {
          _sseHandlers.remove(ch);
          _sseClosers.remove(ch)?.call(reason);
        }
        break;
      case 'http-reply':
        final id = f['id'] as String?;
        final body = (f['body'] as Map?)?.cast<String, dynamic>();
        if (id != null) _onHttpReply(id, f['status'] as int? ?? 502, body);
        break;
      default:
        break;
    }
  }

  Map<String, dynamic> _replyResult(Map<String, dynamic>? body) {
    if (body == null) throw RelayError('empty-reply');
    if (body['ok'] != true) {
      final err = body['error'] as Map? ?? const {};
      throw RelayError(
        (err['code'] as String?) ?? 'rpc-error',
        (err['message'] as String?) ?? 'dsh rpc failed',
      );
    }
    return (body['value'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  /// Call one dsh RPC method; returns the `result.value` map.
  Future<Map<String, dynamic>> rpc(String method, [Map<String, dynamic> payload = const {}]) async {
    _requireChannel();
    final rpcId = _nextId('rpc');
    final completer = Completer<Map<String, dynamic>>();
    _pending[rpcId] = completer;
    _send({
      'v': 1, 'type': 'rpc', 'channel': _nextId('ch'),
      'rpcId': rpcId, 'path': '/api/$method', 'body': payload,
    });
    try {
      final body = await completer.future.timeout(const Duration(seconds: 20));
      return _replyResult(body);
    } on TimeoutException {
      _pending.remove(rpcId);
      throw RelayError('timeout', '$method timed out');
    }
  }

  /// Open an SSE stream; `onFrame` receives translated server-request frames.
  /// Returns the channel id (pass to [closeSse] to cancel).
  String openSse(
    String path, {
    required void Function(SseFrame frame) onFrame,
    void Function(String reason)? onClose,
  }) {
    _requireChannel();
    final ch = _nextId('ch');
    _sseHandlers[ch] = onFrame;
    if (onClose != null) _sseClosers[ch] = onClose;
    _send({'v': 1, 'type': 'sse-open', 'channel': ch, 'path': path, 'body': const {}});
    return ch;
  }

  /// Open a raw mux stream for the WebView proxy: every server frame (verbatim
  /// JSON) is delivered to `onData`; the bridge mirrors dsh's WebSocket.
  String openSseRaw(
    String path, {
    required void Function(String data) onData,
    void Function(String? reason)? onClose,
  }) {
    _requireChannel();
    final ch = _nextId('ch');
    _rawSseHandlers[ch] = onData;
    if (onClose != null) _sseClosers[ch] = onClose;
    _send({'v': 1, 'type': 'sse-open', 'channel': ch, 'path': path, 'body': {'raw': true}});
    return ch;
  }

  /// HTTP request through the tunnel (WebView proxy). Returns status +
  /// base64 body + headers.
  ///
  /// The bridge answers with one or more `http-reply` `part` frames. The
  /// deadline is **idle-based**: the transfer is only aborted when no chunk
  /// has arrived for [httpIdleTimeout] — a multi-MB plugin bundle on a slow
  /// relay link keeps making progress and is never cut off by a total-time
  /// cap (which is what made "plugin load failed" common before).
  Future<({int status, Map<String, String> headers, String bodyB64})> http(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    _requireChannel();
    final id = _nextId('http');
    final ch = _nextId('ch');
    final completer = Completer<Map<String, dynamic>>();
    _pendingHttp[id] = completer;
    _send({
      'v': 1,
      'type': 'http',
      'id': id,
      'channel': ch,
      'method': method,
      'path': path,
      'body': {
        if (headers != null) 'headers': headers,
        if (body != null && body.isNotEmpty) 'body': base64Encode(body),
      },
    });
    final transfer = _HttpTransfer(
      onComplete: (r) {
        _pendingHttp.remove(id);
        _httpTransfers.remove(id);
        if (!completer.isCompleted) completer.complete(r);
      },
      onError: (e) {
        _pendingHttp.remove(id);
        _httpTransfers.remove(id);
        if (!completer.isCompleted) completer.completeError(e);
      },
    )..armIdleTimer();
    _httpTransfers[id] = transfer;
    final r = await completer.future;
    final rb = (r['body'] as Map?)?.cast<String, dynamic>() ?? const {};
    return (
      status: r['status'] as int? ?? 502,
      headers: (rb['headers'] as Map?)?.cast<String, String>() ?? const {},
      bodyB64: rb['body'] as String? ?? '',
    );
  }

  /// Handle one `http-reply` frame: either a complete single-frame reply or
  /// one part of a chunked transfer (`body.part = {index, total}`).
  void _onHttpReply(String id, int status, Map<String, dynamic>? body) {
    final transfer = _httpTransfers[id];
    final part = (body?['part'] as Map?)?.cast<String, dynamic>();
    if (transfer == null || part == null) {
      // Single-frame reply (or a late part after completion): answer the
      // pending request directly.
      final c = _pendingHttp.remove(id);
      _httpTransfers.remove(id);
      transfer?.cancel();
      if (c != null && !c.isCompleted) c.complete({'status': status, 'body': body});
      return;
    }
    if (body?['abort'] == true) {
      // The bridge failed midway through a chunked transfer.
      final message = body?['body'] is String ? body!['body'] as String : 'chunked transfer aborted';
      transfer.fail(RelayError('transport', message));
      return;
    }
    final chunkB64 = body?['body'] as String? ?? '';
    final index = (part['index'] as num?)?.toInt() ?? 0;
    final total = (part['total'] as num?)?.toInt() ?? 1;
    transfer.accept(index, total, status, body?['headers'], chunkB64);
  }

  void closeSse(String channel) {
    _send({'v': 1, 'type': 'sse-close', 'channel': channel, 'body': {'reason': 'cancelled'}});
    _sseHandlers.remove(channel);
    _sseClosers.remove(channel);
  }

  /// Answer an approval/question. `rpcId` must echo the SSE frame's rpcId.
  Future<Map<String, dynamic>> respond(String rpcId, Map<String, dynamic> value) async {
    _requireChannel();
    final channel = _nextId('ch');
    final completer = Completer<Map<String, dynamic>>();
    _pending[rpcId] = completer;
    _send({
      'v': 1, 'type': 'respond', 'channel': channel,
      'rpcId': rpcId, 'path': '/api/respond', 'body': {'ok': true, 'value': value},
    });
    try {
      final body = await completer.future.timeout(const Duration(seconds: 20));
      return _replyResult(body);
    } on TimeoutException {
      _pending.remove(rpcId);
      throw RelayError('timeout', 'respond timed out');
    }
  }

  StreamChannel<dynamic> _requireChannel() {
    final c = _channel;
    if (c == null) throw RelayError('disconnected', 'tunnel is not connected');
    return c;
  }
}

/// Reassembles one chunked `http-reply` transfer.
///
/// Frames arrive with `body.part = {index, total}`; the headers ride on part
/// 0. The transfer completes when every part has arrived, and fails if no
/// part arrives within [httpIdleTimeout] — progress resets the clock, so a
/// slow but alive transfer is never aborted.
class _HttpTransfer {
  _HttpTransfer({required this.onComplete, required this.onError});

  static const httpIdleTimeout = Duration(seconds: 20);

  final void Function(Map<String, dynamic> reply) onComplete;
  final void Function(Object error) onError;

  final List<String?> _chunks = [];
  final Set<int> _seen = {};
  int _total = 0;
  int _status = 502;
  Map<String, dynamic>? _headers;
  Timer? _idle;

  void armIdleTimer() => _resetIdle();

  void _resetIdle() {
    _idle?.cancel();
    _idle = Timer(httpIdleTimeout, () {
      fail(RelayError('timeout', 'http transfer stalled (${_seen.length}/$_total parts)'));
    });
  }

  void accept(int index, int total, int status, Object? headers, String chunkB64) {
    _resetIdle();
    _total = total > 0 ? total : 1;
    _status = status;
    if (headers is Map) _headers ??= headers.cast<String, dynamic>();
    if (index < 0 || index >= _total || !_seen.add(index)) return;
    if (_chunks.length < _total) _chunks.length = _total;
    _chunks[index] = chunkB64;
    if (_seen.length < _total) return;
    // All parts in: concatenate the base64 payloads into one body.
    final bytes = <int>[];
    for (final c in _chunks) {
      if (c == null) return fail(RelayError('transport', 'missing chunk'));
      bytes.addAll(base64Decode(c));
    }
    final reply = {
      'status': _status,
      'body': {
        if (_headers != null) 'headers': _headers,
        'body': base64Encode(bytes),
      },
    };
    _idle?.cancel();
    onComplete(reply);
  }

  void fail(Object error) {
    _idle?.cancel();
    onError(error);
  }

  void cancel() {
    _idle?.cancel();
  }
}
