/// LAN-direct backend: forwards tunnel-style calls straight to the desktop's
/// bridge LAN proxy (`ip:port`) over plain HTTP/WebSocket.
///
/// The WebView always talks to `http://127.0.0.1:<proxy port>` (a fixed port
/// keeps dsh's localStorage origin stable across launches), and this backend
/// is what the proxy talks to in LAN-direct mode. Using the local proxy for
/// LAN traffic too means dsh sees the same origin in every mode, so its
/// session history (localStorage) survives mode switches and restarts.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel_backend.dart';

class LanBackend implements TunnelBackend {
  LanBackend(this.lan);

  /// Desktop bridge LAN address, e.g. "192.168.5.4:13080".
  final String lan;

  final Map<String, WebSocket> _wsByChannel = {};
  final Map<String, void Function(String data)> _handlers = {};
  int _seq = 0;

  @override
  Future<({int status, Map<String, String> headers, String bodyB64})> http(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.openUrl(method, Uri.parse('http://$lan$path'));
      headers?.forEach((k, v) => req.headers.set(k, v));
      if (body != null && body.isNotEmpty) req.add(body);
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 20));
      final respHeaders = <String, String>{};
      resp.headers.forEach((k, v) => respHeaders[k] = v.join(','));
      return (
        status: resp.statusCode,
        headers: respHeaders,
        bodyB64: base64Encode(bytes),
      );
    } finally {
      client.close();
    }
  }

  @override
  String openSseRaw(
    String path, {
    required void Function(String data) onData,
    void Function(String? reason)? onClose,
  }) {
    final ch = 'lan-${_seq++}';
    _handlers[ch] = onData;
    final wsUrl = 'ws://$lan$path';
    WebSocket.connect(wsUrl).then((ws) {
      _wsByChannel[ch] = ws;
      ws.listen(
        (data) {
          final onData2 = _handlers[ch];
          if (onData2 != null && data is String) onData2(data);
        },
        onDone: () {
          _handlers.remove(ch);
          _wsByChannel.remove(ch);
          onClose?.call(null);
        },
        onError: (Object _) {
          _handlers.remove(ch);
          _wsByChannel.remove(ch);
          onClose?.call('error');
        },
      );
    }).catchError((Object e) {
      _handlers.remove(ch);
      onClose?.call('error');
    });
    return ch;
  }

  @override
  void closeSse(String channel) {
    _handlers.remove(channel);
    final ws = _wsByChannel.remove(channel);
    try {
      ws?.close();
    } catch (_) {}
  }

  void dispose() {
    for (final ch in _wsByChannel.keys.toList()) {
      closeSse(ch);
    }
  }
}
