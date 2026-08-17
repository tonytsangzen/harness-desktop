/// Local HTTP server that fronts the relay tunnel for the in-app WebView.
///
/// The WebView loads `http://127.0.0.1:<port>/` — dsh's real frontend served
/// through the tunnel. Every request (page, /assets, /plugins, /api RPC) is
/// forwarded as a tunnel `http` frame to the bridge, which proxies it to the
/// local dsh web. `/api/events.mux|host` are WebSocket upgrades that map to
/// tunnel `sse-open` (raw) streams, so the dsh UI updates live, exactly like
/// on the desktop.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel_backend.dart';

class WebProxy {
  WebProxy(this.client);

  /// Active backend (relay tunnel or LAN-direct).
  final TunnelBackend client;

  HttpServer? _server;
  final Map<String, WebSocket> _wsByChannel = {};

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    // Fixed port keeps the WebView origin stable across launches so dsh's
    // localStorage (active session) survives. Fall back to an ephemeral
    // port if 38080 is taken (e.g. a stale proxy from a crashed process).
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 38080);
    } catch (_) {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    }
    _server!.listen(_handle, onError: (Object e) {});
  }

  Future<void> close() async {
    for (final ch in _wsByChannel.keys) {
      client.closeSse(ch);
    }
    _wsByChannel.clear();
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    final upgrade = (req.headers.value('upgrade') ?? '').toLowerCase();
    if (upgrade == 'websocket' &&
        (path == '/api/events.mux' || path == '/api/events.host')) {
      _handleWs(req);
      return;
    }
    try {
      final bodyBytes = <int>[];
      await for (final chunk in req) {
        bodyBytes.addAll(chunk);
      }
      final headers = <String, String>{};
      req.headers.forEach((name, values) {
        // dsh validates Origin against its own origin (returns 403 otherwise)
        // and binds to its own Host; drop both so the tunnel proxy is neutral.
        final l = name.toLowerCase();
        if (l == 'host' || l == 'origin') return;
        headers[name] = values.join(',');
      });
      final fullPath = req.uri.query.isEmpty
          ? path
          : '$path?${req.uri.query}';
      final r = await client.http(
        req.method,
        fullPath,
        headers: headers,
        body: bodyBytes,
      );
      req.response.statusCode = r.status;
      // Never let the WebView cache tunneled responses: a stale cached
      // response from an earlier buggy build (missing content-type) would
      // keep failing strict-MIME script checks.
      req.response.headers.set('cache-control', 'no-store');
      r.headers.forEach((k, v) {
        if (k.toLowerCase() == 'content-type') {
          try {
            req.response.headers.contentType = ContentType.parse(v);
          } catch (_) {
            req.response.headers.set('content-type', v);
          }
        } else {
          req.response.headers.set(k, v);
        }
      });
      if (r.bodyB64.isNotEmpty) {
        req.response.add(base64Decode(r.bodyB64));
      }
    } catch (e) {
      print('[dsh] proxy error: $e');
      req.response.statusCode = 502;
      req.response.headers.contentType = ContentType.text;
      req.response.write('proxy error: $e');
    }
    await req.response.close();
  }

  void _handleWs(HttpRequest req) {
    WebSocketTransformer.upgrade(req).then((ws) {
      final ch = client.openSseRaw(
        req.uri.path,
        onData: (data) {
          if (ws.readyState == WebSocket.open) ws.add(data);
        },
        onClose: (_) {
          if (ws.readyState == WebSocket.open) ws.close();
        },
      );
      _wsByChannel[ch] = ws;
      ws.listen(
        (_) {},
        onDone: () {
          client.closeSse(ch);
          _wsByChannel.remove(ch);
        },
        onError: (Object _) {},
      );
    }).catchError((Object e) {
      req.response.statusCode = 502;
      req.response.write('ws proxy error: $e');
      req.response.close();
    });
  }
}
