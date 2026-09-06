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

import 'disk_cache.dart';
import 'tunnel_backend.dart';

/// One tunneled HTTP response (record shape shared with [TunnelBackend.http]).
typedef _TunnelResponse = ({int status, Map<String, String> headers, String bodyB64});

class WebProxy {
  /// [disk] overrides the shared [DiskCache] (tests); null resolves the
  /// real one in [start]. Disk failures degrade to the in-memory cache.
  WebProxy(this.client, {DiskCache? disk}) : _diskOverride = disk;

  /// Active backend (relay tunnel or LAN-direct).
  final TunnelBackend client;
  final DiskCache? _diskOverride;
  DiskCache? _disk;

  HttpServer? _server;
  final Map<String, WebSocket> _wsByChannel = {};

  // Small in-memory cache for dsh's fingerprinted static assets and plugin
  // bundles. Every tunneled request costs a full phone↔relay↔desktop round
  // trip, and the frontend loads many assets on each visit; caching the
  // hash-named files (whose URL changes whenever the content changes, so
  // stale entries are impossible) and rev-keyed /plugins/ bundles makes
  // re-entering a terminal near-instant and keeps plugin loads off the slow
  // relay link entirely after the first fetch.
  static const int _maxCacheBytes = 24 * 1024 * 1024;
  static const int _maxCacheEntryBytes = 8 * 1024 * 1024;
  final Map<String, _CachedResponse> _cache = {};
  int _cacheBytes = 0;

  /// Open raw mux channels streaming HTTP SSE into WebView responses.
  final Set<String> _sseChannels = {};

  /// In-flight tunnel GETs by URL: parallel identical requests (a page load
  /// fires many) share one tunnel round trip instead of racing the queue.
  final Map<String, Future<_TunnelResponse>> _inflight = {};

  int get port => _server?.port ?? 0;

  bool _isCacheable(String method, String path, String query) {
    if (method != 'GET') return false;
    if (path.startsWith('/assets/')) return true;
    // Plugin bundles are static client scripts keyed by a rev param, so a
    // query-bearing URL is immutable in practice.
    if (path.startsWith('/plugins/') && query.contains('rev=')) return true;
    return false;
  }

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
    if (_disk == null) {
      try {
        _disk = _diskOverride ?? await DiskCache.instance();
      } catch (_) {
        _disk = null; // no storage: in-memory cache still works
      }
    }
  }

  Future<void> close() async {
    for (final ch in _wsByChannel.keys) {
      client.closeSse(ch);
    }
    _wsByChannel.clear();
    for (final ch in _sseChannels) {
      client.closeSse(ch);
    }
    _sseChannels.clear();
    _inflight.clear();
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
    // /plugins/events is an HTTP SSE stream that never ends. Tunneled as a
    // plain HTTP request it stalls until the relay timeout (one long
    // stall on every connect). Stream it through a raw mux channel instead.
    if (path == '/plugins/events') {
      _handleSseStream(req);
      return;
    }
    try {
      await _handleHttp(req);
    } catch (e) {
      print('[dsh] proxy error: $e');
      req.response.statusCode = 502;
      req.response.headers.contentType = ContentType.text;
      req.response.write('proxy error: $e');
    }
    // Terminate EVERY plain HTTP response — including the cache-hit early
    // returns inside _handleHttp. Without close() the keep-alive connection
    // never completes and the WebView request hangs forever.
    await req.response.close();
  }

  Future<void> _handleHttp(HttpRequest req) async {
    final path = req.uri.path;
    {
      final fullPath = req.uri.query.isEmpty
          ? path
          : '$path?${req.uri.query}';
      final cacheable = _isCacheable(req.method, path, req.uri.query);
      if (cacheable) {
        final hit = _cache[fullPath];
        if (hit != null) {
          _serveCached(req, hit);
          return;
        }
        // Persistent layer: URLs here carry their content hash, so a hit
        // needs no revalidation — zero tunnel traffic for unchanged files.
        final entry = await _disk?.get(fullPath);
        if (entry != null && entry.body.isNotEmpty) {
          _store(fullPath, entry.status, entry.headers, entry.body);
          _serveCached(req, _CachedResponse(entry.status, entry.headers, entry.body));
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
      // The entry document ("/") is mutable (no content hash), so it carries
      // a bridge-issued ETag: re-send If-None-Match and a 304 replaces a
      // ~15KB download with a round trip.
      final isEntryDoc = req.method == 'GET' && path == '/';
      DiskCacheEntry? doc;
      if (isEntryDoc && _disk != null) {
        doc = await _disk!.get(path);
        // Only revalidate when we truly hold the body — a 304 without a
        // stored document would leave the WebView without an answer.
        if (doc != null && doc.body.isNotEmpty && doc.etag != null) {
          headers['if-none-match'] = doc.etag!;
        } else {
          doc = null;
        }
      }
      var r = await _tunnel(req.method, fullPath, headers, bodyBytes);
      if (r.status == 304 && doc != null && doc.body.isNotEmpty) {
        // Tunnel-level "unchanged": answer the WebView from disk.
        r = (status: 200, headers: doc.headers, bodyB64: base64Encode(doc.body));
      }
      var respBody = r.bodyB64.isNotEmpty ? base64Decode(r.bodyB64) : const <int>[];
      var respHeaders = Map<String, String>.from(r.headers);
      // The bridge gzips large bodies for the relay downlink; localhost
      // serving gains nothing from it, and both the polyfill injection and
      // the disk cache operate on plain bytes. (Before this normalization
      // the gzip layer silently disabled polyfill injection for >2KB docs.)
      final encoding = respHeaders['content-encoding']?.toLowerCase();
      if (encoding == 'gzip' && respBody.isNotEmpty) {
        try {
          respBody = GZipCodec().decode(respBody);
          respHeaders
            ..remove('content-encoding')
            ..remove('Content-Encoding')
            ..remove('content-length')
            ..remove('Content-Length');
        } catch (_) {
          // Not actually gzip (or corrupt): serve as-is.
        }
      }
      // Raw (pre-injection) bytes: what the entry-document record persists.
      final rawPlain = List<int>.of(respBody);
      // Inject the AbortSignal polyfill into the HTML entry document (only
      // when it is uncompressed text/html). Old Android system WebViews
      // (pre-Chrome 116) lack AbortSignal.any/timeout, which the dsh UI calls
      // when collecting agent messages; injecting here — before any page
      // script runs — fixes it for every WebView, no user-script API needed.
      if (!cacheable && r.status == 200 && respBody.isNotEmpty &&
          _isHtmlResponse(r.headers)) {
        final injected = _injectAbortSignalPolyfill(respBody);
        if (injected != null) {
          respBody = injected;
          respHeaders
            ..remove('content-length')
            ..remove('Content-Length')
            // Never let the WebView cache an injected document: a stale
            // cached copy from a buggy build (corrupted by a bad injection)
            // would keep showing broken markup forever.
            ..remove('cache-control')
            ..remove('Cache-Control')
            ..['cache-control'] = 'no-store';
          // Cache the injected document in the proxy LRU too: the entry page
          // is fetched on every launch and the relay downlink is slow, so
          // serving it from memory makes re-entry near-instant.
          _store(fullPath, r.status, respHeaders, respBody);
        }
      }
      if (cacheable && r.status == 200) {
        _store(fullPath, r.status, respHeaders, respBody);
        // Persist content-addressed resources so the NEXT connection (and
        // app restart) serves them from disk without any tunnel round trip.
        _disk?.put(fullPath,
            status: r.status, headers: respHeaders, body: respBody);
      }
      if (isEntryDoc && r.status == 200 && _disk != null) {
        // Store the RAW (pre-injection) document + its ETag; the injected
        // variant is derived at serve time, so the stored bytes stay valid
        // across app updates.
        _disk?.put(path,
            status: r.status,
            headers: Map.of(respHeaders)..['cache-control'] = 'no-store',
            body: rawPlain,
            etag: r.headers['etag'] ?? r.headers['ETag']);
      }
      _serveCached(req, _CachedResponse(r.status, respHeaders, respBody));
    }
  }

  /// One tunneled request with in-flight coalescing and one automatic retry
  /// for idempotent methods (a timed-out GET is very likely a transient relay
  /// hiccup; without the retry the page shows "Failed to load plugins").
  /// The retry lives inside the shared future: when N parallel requests
  /// coalesce onto one tunnel call, one retry recovers all of them.
  Future<_TunnelResponse> _tunnel(
      String method, String fullPath, Map<String, String> headers, List<int> body) {
    if (method != 'GET' && method != 'HEAD') {
      return client.http(method, fullPath, headers: headers, body: body);
    }
    final existing = _inflight[fullPath];
    if (existing != null) return existing;
    final f = _issueWithRetry(method, fullPath, headers, body);
    _inflight[fullPath] = f;
    return f.whenComplete(() => _inflight.remove(fullPath));
  }

  Future<_TunnelResponse> _issueWithRetry(String method, String fullPath,
      Map<String, String> headers, List<int> body) async {
    try {
      return await client.http(method, fullPath, headers: headers, body: body);
    } on Object {
      // A second failure propagates to every waiter.
      return client.http(method, fullPath, headers: headers, body: body);
    }
  }

  void _store(String key, int status, Map<String, String> headers, List<int> body) {
    // One oversized entry (a huge plugin bundle) must not evict everything
    // else — skip caching it instead.
    if (body.length > _maxCacheEntryBytes) return;
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

  /// Only ever inject into real HTML documents. Plugin/client bundles are
  /// JavaScript and may contain `<head`/`<html` inside string literals — the
  /// earlier body-sniffing heuristic corrupted them (a bundle starting with
  /// `<script>…</script>` fails to load: "loaded without registering …").
  bool _isHtmlResponse(Map<String, String> headers) {
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'content-type' &&
          e.value.toLowerCase().contains('text/html')) {
        return true;
      }
    }
    return false;
  }

  /// Returns the HTML with the AbortSignal polyfill script inserted right
  /// after the `<head>` open tag (or at the very start when no head tag is
  /// found), or null when the body is not HTML. The script runs before any
  /// deferred/module page script, so old WebViews see AbortSignal.any/timeout
  /// defined. Insertion must land *after* the head tag's closing `>` — going
  /// between `<head` and `>` corrupts the markup and the script shows up as
  /// visible text.
  List<int>? _injectAbortSignalPolyfill(List<int> html) {
    final text = utf8.decode(html, allowMalformed: true);
    if (!text.contains('<html') && !text.contains('<head') &&
        !RegExp(r'<!doctype\s+html', caseSensitive: false).hasMatch(text)) {
      return null;
    }
    const script = '<script>${_abortSignalPolyfillJs}</script>';
    int insertAt = 0;
    final headIdx = text.indexOf('<head');
    if (headIdx >= 0) {
      final gt = text.indexOf('>', headIdx);
      insertAt = gt >= 0 ? gt + 1 : headIdx + 5;
    }
    final injected = text.substring(0, insertAt) + script + text.substring(insertAt);
    return utf8.encode(injected);
  }

  /// Polyfill for AbortSignal.any / AbortSignal.timeout (Chrome 116+).
  /// Injected into the HTML document before page scripts run.
  static const String _abortSignalPolyfillJs = r'''
(function () {
  try {
    if (typeof AbortSignal !== 'undefined' && !AbortSignal.any) {
      AbortSignal.any = function (signals) {
        var c = new AbortController();
        signals = signals || [];
        for (var i = 0; i < signals.length; i++) {
          var s = signals[i];
          if (!s || s.aborted) {
            c.abort(s && s.reason);
            return c.signal;
          }
          s.addEventListener('abort', function () {
            c.abort(this.reason);
          }, { once: true });
        }
        return c.signal;
      };
    }
    if (typeof AbortSignal !== 'undefined' && !AbortSignal.timeout) {
      AbortSignal.timeout = function (ms) {
        var c = new AbortController();
        setTimeout(function () {
          c.abort(new DOMException('The operation timed out.', 'TimeoutError'));
        }, ms);
        return c.signal;
      };
    }
  } catch (e) { /* never break the page */ }
})();
''';

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

  /// Stream an HTTP SSE endpoint (e.g. /plugins/events) through a raw mux
  /// channel instead of buffering it as a one-shot HTTP response. The
  /// response stays open and each tunneled chunk is written as it arrives.
  void _handleSseStream(HttpRequest req) {
    req.response.statusCode = 200;
    req.response.headers.contentType = ContentType('text', 'event-stream');
    req.response.headers.set('cache-control', 'no-store');
    // Dart buffers the headers until the first write or close; an idle SSE
    // stream may never emit data, so flush the 200 now — otherwise the
    // WebView waits for the response headers forever and the page never
    // finishes loading.
    req.response.flush();
    final ch = client.openSseRaw(
      req.uri.path,
      onData: (data) {
        try {
          req.response.add(utf8.encode(data));
        } catch (_) {
          // Response already closed; the channel teardown handles cleanup.
        }
      },
      onClose: (_) {
        try {
          req.response.close();
        } catch (_) {}
      },
    );
    _sseChannels.add(ch);
    req.response.done.whenComplete(() {
      client.closeSse(ch);
      _sseChannels.remove(ch);
    }).catchError((Object _) {});
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
