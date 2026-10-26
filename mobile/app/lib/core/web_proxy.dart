/// Local TCP endpoint for the WebView.
///
/// Every accepted WebView connection becomes one opaque remote port stream;
/// request/response bodies, WebSocket frames and all application bytes are
/// forwarded unchanged. Two HTTP-level accommodations remain, for old Android
/// system WebViews (e.g. Huawei devices stuck on Chromium 114) that the dsh
/// UI would otherwise crash on:
///
/// 1. Every request is rewritten to `Accept-Encoding: identity`, so
///    responses arrive uncompressed.
/// 2. Uncompressed `text/html` responses get the dsh polyfill script
///    injected right after the `<head>` open tag — before any page script
///    runs — polyfilling `Promise.withResolvers` (Chrome 119+) and
///    `AbortSignal.any` (Chrome 116+). Injected documents are forced to
///    `cache-control: no-store` so a stale copy can never be served again.
///
/// WebSocket upgrades switch the connection to fully transparent
/// passthrough. Only HTTP/1.1 keep-alive framing is tracked (request
/// Content-Length; response Content-Length or chunked), which is all
/// browsers use over this proxy.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel_backend.dart';

const CRLF = '\r\n';

class WebProxy {
  WebProxy(this.backend, {this.remotePort = 3080});
  final PortBackend backend;
  final int remotePort;
  ServerSocket? _server;
  final Set<Socket> _clients = {};
  final Set<PortConnection> _remotes = {};

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    // Prefer the remote dsh port so the WebView origin matches the desktop
    // exactly (dsh binds its auth cookie to the Host authority); fall back
    // to the historical fixed port, then to an ephemeral one.
    for (final port in [remotePort, 38080, 0]) {
      try {
        _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        break;
      } catch (_) {
        if (port == 0) rethrow;
      }
    }
    _server!.listen(_accept, onError: (_) {});
  }

  Future<void> _accept(Socket client) async {
    _clients.add(client);
    PortConnection? remote;
    try {
      remote = await backend.connectPort(remotePort);
      _remotes.add(remote);
      final connection = remote;
      final state = _ConnectionState();
      final down = _Downlink(state, client.add);
      final remoteSubscription = connection.input.listen(
        down.add,
        onDone: client.destroy,
        onError: (_) => client.destroy(),
        cancelOnError: true,
      );
      final up = _Uplink(state, connection.add);
      late StreamSubscription<List<int>> clientSubscription;
      clientSubscription = client.listen(
        up.add,
        onDone: () async {
          await connection.close();
          await remoteSubscription.cancel();
        },
        onError: (_, _) async {
          await connection.close();
          await remoteSubscription.cancel();
        },
        cancelOnError: true,
      );
      client.done.whenComplete(() async {
        await clientSubscription.cancel();
        await connection.close();
      });
    } catch (_) {
      await remote?.close();
      client.destroy();
    } finally {
      client.done.whenComplete(() {
        _clients.remove(client);
        if (remote != null) _remotes.remove(remote);
      });
    }
  }

  Future<void> close() async {
    for (final client in _clients.toList()) {
      client.destroy();
    }
    for (final remote in _remotes.toList()) {
      await remote.close();
    }
    _clients.clear();
    _remotes.clear();
    await _server?.close();
    _server = null;
  }

  /// Polyfill for browser APIs the dsh UI calls that old Android system
  /// WebViews lack (injected into HTML before any page script runs).
  static const String polyfillJs = r'''
(function () {
  try {
    if (typeof Promise !== 'undefined' && !Promise.withResolvers) {
      Promise.withResolvers = function () {
        var resolve, reject;
        var promise = new Promise(function (res, rej) {
          resolve = res;
          reject = rej;
        });
        return { promise: promise, resolve: resolve, reject: reject };
      };
    }
    if (typeof AbortSignal !== 'undefined') {
      if (!AbortSignal.any) {
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
      if (!AbortSignal.timeout) {
        AbortSignal.timeout = function (ms) {
          var c = new AbortController();
          setTimeout(function () {
            c.abort(new DOMException('The operation timed out.', 'TimeoutError'));
          }, ms);
          return c.signal;
        };
      }
    }
  } catch (e) { /* never break the page */ }
})();
''';
}

/// State shared by the two direction state machines of one TCP connection.
class _ConnectionState {
  String requestMethod = 'GET';
  bool upgraded = false;
}

/// Exclusive end index of the HTTP head (including the final CRLFCRLF)
/// starting at [start], or -1 when incomplete.
int _findHeadEnd(List<int> bytes, int start) {
  for (var i = start + 3; i < bytes.length; i++) {
    if (bytes[i - 3] == 13 &&
        bytes[i - 2] == 10 &&
        bytes[i - 1] == 13 &&
        bytes[i] == 10) {
      return i + 1;
    }
  }
  return -1;
}

/// Index of [pattern] in [bytes] at or after [start], or -1.
int _indexOf(List<int> bytes, List<int> pattern, int start) {
  outer:
  for (var i = start; i <= bytes.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

final _headPattern = '<head'.codeUnits;
final _gtPattern = '>'.codeUnits;
final _htmlPattern = '<html'.codeUnits;
final _doctypePattern = '<!doctype'.codeUnits;
final _doctypeUpperPattern = '<!DOCTYPE'.codeUnits;

// ---------------------------------------------------------------------------
// WebView → dsh direction
// ---------------------------------------------------------------------------

/// Rewrites every request head (`Accept-Encoding: identity` so the polyfill
/// can be injected into HTML responses) and detects WebSocket upgrades, after
/// which the connection is forwarded fully transparently.
class _Uplink {
  _Uplink(this._state, this._send);
  final _ConnectionState _state;
  final void Function(List<int>) _send;

  final List<int> _buf = [];
  bool _transparent = false;
  bool _inBody = false;
  int _bodyRemaining = 0;

  void add(List<int> bytes) {
    if (_transparent) {
      _send(bytes);
      return;
    }
    _buf.addAll(bytes);
    _drain();
  }

  void _drain() {
    var pos = 0;
    while (!_transparent) {
      if (_inBody) {
        final n = _bodyRemaining < _buf.length - pos
            ? _bodyRemaining
            : _buf.length - pos;
        if (n == 0) break;
        _send(_buf.sublist(pos, pos + n));
        pos += n;
        _bodyRemaining -= n;
        if (_bodyRemaining == 0) _inBody = false;
        continue;
      }
      final headEnd = _findHeadEnd(_buf, pos);
      if (headEnd < 0) {
        if (_buf.length - pos > 32 * 1024) {
          // Not HTTP (or absurd): give up rewriting, forward as-is forever.
          _transparent = true;
          _state.upgraded = true;
          _send(_buf.sublist(pos));
          pos = _buf.length;
        }
        break;
      }
      final parsed = _rewriteRequestHead(_buf.sublist(pos, headEnd));
      pos = headEnd;
      _send(parsed.$1);
      if (parsed.$2) {
        // WebSocket upgrade: everything after this head is opaque framing.
        _transparent = true;
        _state.upgraded = true;
        if (_buf.length > pos) _send(_buf.sublist(pos));
        pos = _buf.length;
        break;
      }
      if (parsed.$3 > 0) {
        _inBody = true;
        _bodyRemaining = parsed.$3;
      }
    }
    if (pos > 0) _buf.removeRange(0, pos);
  }

  /// Returns (rewritten head, isUpgrade, requestContentLength).
  (List<int>, bool, int) _rewriteRequestHead(List<int> headBytes) {
    final text = utf8.decode(headBytes, allowMalformed: true);
    final lines = text.split('\r\n'); // ends with the two empty terminator rows
    final out = <String>[lines.first];
    var contentLength = 0;
    var upgraded = false;
    var sawEncoding = false;
    for (final line in lines.skip(1)) {
      final at = line.indexOf(':');
      if (at <= 0) {
        out.add(line);
        continue;
      }
      final name = line.substring(0, at).trim().toLowerCase();
      if (name == 'accept-encoding') {
        out.add('Accept-Encoding: identity');
        sawEncoding = true;
      } else {
        if (name == 'content-length') {
          contentLength = int.tryParse(line.substring(at + 1).trim()) ?? 0;
        } else if (name == 'upgrade' &&
            line.substring(at + 1).trim().toLowerCase() == 'websocket') {
          upgraded = true;
        }
        out.add(line);
      }
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    if (!sawEncoding) out.add('Accept-Encoding: identity');
    _state.requestMethod = lines.first.split(' ').first.toUpperCase();
    return (utf8.encode('${out.join('\r\n')}\r\n\r\n'), upgraded, contentLength);
  }
}

// ---------------------------------------------------------------------------
// dsh → WebView direction
// ---------------------------------------------------------------------------

class _Downlink {
  _Downlink(this._state, this._send);
  final _ConnectionState _state;
  final void Function(List<int>) _send;

  final List<int> _buf = [];
  final _ChunkScanner _scanner = _ChunkScanner();

  bool _inHead = true;
  bool _scanning = false; // injectable response: scanning for `<head>`
  int _countdown = 0; // remaining Content-Length body bytes
  bool _chunkPassthrough = false; // chunked framing being streamed through

  /// Scanned body bytes of the response currently being scanned.
  final List<int> _scanBody = [];
  List<String> _pendingHeadLines = const [];
  int _pendingContentLength = -1;

  /// Body prefix scanned for the insertion point before giving up.
  static const int _maxScanBodyBytes = 64 * 1024;

  void add(List<int> bytes) {
    print(
      '[dl] add ${bytes.length}B upgraded=${_state.upgraded} inHead=$_inHead',
    );
    if (_state.upgraded) {
      _send(bytes);
      return;
    }
    _buf.addAll(bytes);
    _drain();
  }

  void _sink(List<int> buf, int start, int end) =>
      _send(buf.sublist(start, end));

  void _drain() {
    var pos = 0;
    var progressed = true;
    while (progressed) {
      progressed = false;
      if (_inHead) {
        final headEnd = _findHeadEnd(_buf, pos);
        if (headEnd < 0) break;
        _onHead(_buf.sublist(pos, headEnd));
        pos = headEnd;
        progressed = true;
        continue;
      }
      if (_scanning) {
        final before = pos;
        pos = _scan(pos);
        progressed = pos > before;
        continue;
      }
      if (_countdown > 0) {
        final n = _countdown < _buf.length - pos
            ? _countdown
            : _buf.length - pos;
        if (n == 0) break;
        _sink(_buf, pos, pos + n);
        pos += n;
        _countdown -= n;
        if (_countdown == 0) _inHead = true;
        progressed = true;
        continue;
      }
      if (_chunkPassthrough) {
        final before = pos;
        pos = _scanner.scan(_buf, pos, (_, _, _) {});
        if (pos > before) {
          // Passthrough forwards framing bytes and data alike.
          _sink(_buf, before, pos);
          progressed = true;
        }
        if (_scanner.done) {
          _chunkPassthrough = false;
          _inHead = true;
          progressed = true;
        }
        continue;
      }
      break;
    }
    if (pos > 0) _buf.removeRange(0, pos);
  }

  void _onHead(List<int> headBytes) {
    final text = utf8.decode(headBytes, allowMalformed: true);
    final lines = text.split('\r\n');
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    final status = int.tryParse(lines.first.split(' ').elementAt(1)) ?? 0;
    final bodyless =
        status < 200 ||
        status == 204 ||
        status == 304 ||
        _state.requestMethod == 'HEAD';
    if (bodyless) {
      _send(headBytes);
      _inHead = true;
      return;
    }

    var contentType = '';
    var contentEncoding = '';
    var contentLength = -1;
    var chunked = false;
    for (final line in lines.skip(1)) {
      final at = line.indexOf(':');
      if (at <= 0) continue;
      final name = line.substring(0, at).trim().toLowerCase();
      final value = line.substring(at + 1).trim();
      if (name == 'content-type') contentType = value.toLowerCase();
      if (name == 'content-encoding') contentEncoding = value.toLowerCase();
      if (name == 'content-length') contentLength = int.tryParse(value) ?? -1;
      if (name == 'transfer-encoding' &&
          value.toLowerCase().contains('chunked')) {
        chunked = true;
      }
    }

    final injectable =
        status == 200 &&
        contentType.contains('text/html') &&
        contentEncoding.isEmpty;

    if (!injectable) {
      _send(headBytes);
      _inHead = false;
      if (chunked) {
        _chunkPassthrough = true;
        _scanner.start();
        _inHead = false;
      } else if (contentLength > 0) {
        _countdown = contentLength;
        _inHead = false;
      } else if (contentLength == 0) {
        // Empty body: immediately ready for the next response.
        _inHead = true;
      } else {
        // No usable framing (connection-close body): stop parsing.
        _state.upgraded = true; // reuse the "raw forever" switch
      }
      return;
    }

    // Injection candidate: hold the head until the body scan decides, then
    // emit it rewritten (content-length adjusted, cache-control no-store).
    _scanning = true;
    _scanBody.clear();
    _pendingHeadLines = lines;
    _pendingContentLength = contentLength;
    if (chunked) {
      _chunkPassthrough = true;
      _scanner.start();
    }
    _inHead = false;
  }

  /// Collect scanned body bytes while looking for the `<head>` insertion
  /// point; decides and emits once possible. Returns the new position.
  int _scan(int pos) {
    final chunked = _chunkPassthrough;
    final capLeft = _maxScanBodyBytes - _scanBody.length;
    if (chunked) {
      pos = _scanner.scan(_buf, pos, _collectScan);
    } else {
      var limit = _buf.length;
      if (_pendingContentLength >= 0) {
        final framed = pos + _pendingContentLength - _scanBody.length;
        if (framed < limit) limit = framed;
      }
      if (limit - pos > capLeft) limit = pos + capLeft;
      if (limit > pos) {
        _collectScan(_buf, pos, limit);
        pos = limit;
      }
    }
    final insertion = _findInsertion();
    final bodyComplete = chunked ? _scanner.done : _bodyCollected();
    final capReached = _scanBody.length >= _maxScanBodyBytes;
    if (chunked) {
      // Only emit at a chunk boundary: the injected bytes are re-framed as
      // one synthetic chunk and the passthrough must resume at the next
      // original chunk's size line, never in the middle of chunk data.
      final boundary = _scanner.atBoundary;
      if (!boundary) return pos;
      if (!insertion.found && !bodyComplete && !capReached) return pos;
    } else {
      if (!insertion.found && !bodyComplete && !capReached) return pos;
    }
    _emitScanResult(insertion);
    return pos;
  }

  void _collectScan(List<int> buf, int start, int end) =>
      _scanBody.addAll(buf.getRange(start, end));

  bool _bodyCollected() =>
      _pendingContentLength >= 0 && _scanBody.length >= _pendingContentLength;

  /// Insertion offset into [_scanBody] (after the `<head …>` open tag), a
  /// negative value while the scan is still inconclusive.
  _Insertion _findInsertion() {
    final headIdx = _indexOf(_scanBody, _headPattern, 0);
    if (headIdx < 0) return _Insertion.notYet;
    final gt = _indexOf(_scanBody, _gtPattern, headIdx);
    if (gt < 0) return _Insertion.notYet; // need the tag's closing `>`
    return _Insertion(true, gt + 1);
  }

  void _emitScanResult(_Insertion insertion) {
    _scanning = false;
    final lines = _pendingHeadLines;
    final chunked = _chunkPassthrough;
    final body = List<int>.of(_scanBody);
    _scanBody.clear();

    var injectAt = insertion.found ? insertion.offset : -1;
    if (injectAt < 0 && _htmlMarkerSeen(body)) {
      // No `<head>` in the document (or beyond the scan window): the very
      // start of the body is still parsed as an implicit head, so the
      // script runs before any page script either way.
      injectAt = 0;
    }

    var head = '${lines.join('\r\n')}\r\n\r\n';
    var payload = body;
    if (injectAt >= 0) {
      final script = utf8.encode('<script>${WebProxy.polyfillJs}</script>');
      payload = <int>[
        ...body.sublist(0, injectAt),
        ...script,
        ...body.sublist(injectAt),
      ];
      final delta = payload.length - body.length;
      final out = <String>[lines.first];
      var hasCacheControl = false;
      for (final line in lines.skip(1)) {
        final at = line.indexOf(':');
        final name = at > 0 ? line.substring(0, at).trim().toLowerCase() : '';
        if (name == 'cache-control') {
          hasCacheControl = true;
          out.add('Cache-Control: no-store');
        } else if (name == 'content-length') {
          final original = int.tryParse(line.substring(at + 1).trim()) ?? 0;
          out.add('Content-Length: ${original + delta}');
        } else {
          out.add(line);
        }
      }
      if (!hasCacheControl) out.add('Cache-Control: no-store');
      head = '${out.join('\r\n')}\r\n\r\n';
    }
    // Chunked responses: the scanner consumed the original chunk framing
    // while scanning, so the collected data must be re-framed as one
    // synthetic chunk whether or not anything was injected — emitting it raw
    // would make the browser parse HTML text as chunk-size lines and corrupt
    // everything that follows. The passthrough resumes at the next original
    // chunk's size line; when the scan already consumed the terminal chunk,
    // a fresh one terminates the re-framed stream.
    if (chunked) {
      payload = [
        ...utf8.encode('${payload.length.toRadixString(16)}\r\n'),
        ...payload,
        ...utf8.encode('\r\n'),
      ];
      if (_scanner.done) {
        payload.addAll(utf8.encode('0\r\n\r\n'));
      }
    }
    _send(utf8.encode(head));
    if (payload.isNotEmpty) _send(payload);

    if (chunked) {
      if (_scanner.done) _inHead = true;
      // else: keep streaming the rest through the scanner.
    } else {
      final remaining = _pendingContentLength - body.length;
      if (remaining > 0) {
        _countdown = remaining;
      } else {
        _inHead = true;
      }
    }
  }

  static bool _htmlMarkerSeen(List<int> body) =>
      _indexOf(body, _htmlPattern, 0) >= 0 ||
      _indexOf(body, _doctypePattern, 0) >= 0 ||
      _indexOf(body, _doctypeUpperPattern, 0) >= 0;
}

class _Insertion {
  const _Insertion(this.found, [this.offset = -1]);
  static const notYet = _Insertion(false);
  final bool found;
  final int offset;
}

/// Incremental chunked-transfer framing scanner. Body data bytes are handed
/// to a sink while the scanner tracks chunk boundaries; [done] becomes true
/// once the terminal (zero-length) chunk has been consumed.
class _ChunkScanner {
  bool done = false;

  /// True when the next unconsumed byte starts a new chunk (or the terminal
  /// chunk has been consumed) — the only safe resume points for passthrough.
  bool get atBoundary => done || _mode == 0;
  final List<int> _line = [];
  int _dataRemaining = 0;
  // 0 = size line, 1 = chunk data, 2 = CRLF after chunk data, 3 = trailers.
  int _mode = 0;

  void start() {
    done = false;
    _mode = 0;
    _dataRemaining = 0;
    _line.clear();
  }

  /// Scan [buf] from [start], handing body data to [sink]. Returns the index
  /// of the first byte that belongs to the next response (or buf.length).
  int scan(List<int> buf, int start, void Function(List<int>, int, int) sink) {
    var i = start;
    while (i < buf.length && !done) {
      switch (_mode) {
        case 0:
          final nl = _crlfAt(buf, i);
          if (nl < 0) {
            _line.addAll(buf.getRange(i, buf.length));
            i = buf.length;
            break;
          }
          _line.addAll(buf.getRange(i, nl));
          final size =
              int.tryParse(
                latin1.decode(_line).split(';').first.trim(),
                radix: 16,
              ) ??
              -1;
          _line.clear();
          i = nl + 2;
          if (size < 0) {
            done = true; // broken framing: stop scanning
          } else if (size == 0) {
            _mode = 3;
          } else {
            _dataRemaining = size;
            _mode = 1;
          }
        case 1:
          final n = _dataRemaining < buf.length - i
              ? _dataRemaining
              : buf.length - i;
          if (n > 0) {
            sink(buf, i, i + n);
            i += n;
            _dataRemaining -= n;
          }
          if (_dataRemaining == 0 && i < buf.length) _mode = 2;
        case 2:
          // CRLF after the chunk data; tolerate a lone LF or a garbage byte.
          if (buf[i] == 13) {
            i++;
            if (i < buf.length) {
              if (buf[i] == 10) i++;
              _mode = 0;
            }
          } else {
            if (buf[i] == 10) i++;
            _mode = 0;
          }
        case 3:
          final nl = _crlfAt(buf, i);
          if (nl < 0) {
            i = buf.length;
            break;
          }
          final empty = nl == i;
          i = nl + 2;
          if (empty) done = true;
      }
    }
    return i;
  }

  int _crlfAt(List<int> buf, int start) {
    for (var i = start; i < buf.length - 1; i++) {
      if (buf[i] == 13 && buf[i + 1] == 10) return i;
    }
    return -1;
  }
}
