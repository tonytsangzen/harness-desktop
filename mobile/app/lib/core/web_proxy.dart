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

  // Small in-memory cache for dsh's fingerprinted static assets. Every
  // tunneled request costs a full phone↔relay↔desktop round trip, and the
  // frontend loads many assets on each visit; caching the hash-named files
  // (whose URL changes whenever the content changes, so stale entries are
  // impossible) makes re-entering a terminal near-instant.
  static const int _maxCacheBytes = 8 * 1024 * 1024;
  final Map<String, _CachedResponse> _cache = {};
  int _cacheBytes = 0;

  int get port => _server?.port ?? 0;

  bool _isCacheable(String method, String path) =>
      method == 'GET' && path.startsWith('/assets/');

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
    _cache.clear();
    _cacheBytes = 0;
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
      final fullPath = req.uri.query.isEmpty
          ? path
          : '$path?${req.uri.query}';
      final cacheable = _isCacheable(req.method, path);
      if (cacheable) {
        final hit = _cache[fullPath];
        if (hit != null) {
          _serveCached(req, hit);
          return;
        }
      }
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
      final r = await client.http(
        req.method,
        fullPath,
        headers: headers,
        body: bodyBytes,
      );
      final respBody = r.bodyB64.isNotEmpty ? base64Decode(r.bodyB64) : const <int>[];
      if (cacheable && r.status == 200) {
        _store(fullPath, r.status, r.headers, respBody);
      }
      _serveCached(req, _CachedResponse(r.status, r.headers, respBody));
    } catch (e) {
      print('[dsh] proxy error: $e');
      req.response.statusCode = 502;
      req.response.headers.contentType = ContentType.text;
      req.response.write('proxy error: $e');
    }
    await req.response.close();
  }

  void _store(String key, int status, Map<String, String> headers, List<int> body) {
    final existing = _cache.remove(key);
    if (existing != null) _cacheBytes -= existing.size;
    final entry = _CachedResponse(status, headers, body);
    _cacheBytes += entry.size;
    _cache[key] = entry;
    // Drop oldest entries (insertion order) until under the cap.
    while (_cacheBytes > _maxCacheBytes && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      final removed = _cache.remove(oldest)!;
      _cacheBytes -= removed.size;
    }
  }

  void _serveCached(HttpRequest req, _CachedResponse r) {
    req.response.statusCode = r.status;
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
    if (r.body.isNotEmpty) {
      req.response.add(r.body);
    }
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

/// A cached tunneled response (status + headers + decoded body).
class _CachedResponse {
  _CachedResponse(this.status, this.headers, this.body);

  final int status;
  final Map<String, String> headers;
  final List<int> body;

  int get size => body.length;
}
