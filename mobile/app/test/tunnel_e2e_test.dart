/// Full-tunnel E2E: fake dsh (token→cookie auth + SSE) behind a real relay and
/// bridge, reached through the app's RelayClient + WebProxy — the exact path
/// the WebView uses in tunnel mode.
///
/// Skipped when `go` or `node` is unavailable (machines without the
/// toolchains); everything else runs in-process.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:dsh_mobile/core/relay_client.dart';
import 'package:dsh_mobile/core/web_proxy.dart';

const _pin = '864209';

/// 32 zero bytes base64url — the QR would carry the same value to the app.
const _e2eSecret = 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE';

Future<bool> _hasBin(String bin) async {
  final result = await Process.run('which', [bin]);
  return result.exitCode == 0;
}

void main() {
  test(
    'tunnel e2e: token exchange, keep-alive cookie reuse, SSE live stream',
    () async {
      if (!await _hasBin('go') || !await _hasBin('node')) {
        markTestSkipped('go/node toolchain unavailable');
      }
      // flutter test runs with CWD = mobile/app; the mobile workspace root is
      // one level up.
      final mobileRoot = Directory('..').absolute.path;

      // --- 1. Fake dsh: launch-token auth + API + SSE, like the real one.
      final dsh = await _FakeDsh.bind();
      addTearDown(dsh.close);

      // --- 2. Real relay (go).
      final relayPort = await _freePort();
      final bin = await _buildRelay('$mobileRoot/relay');
      final relay = await Process.start(bin, [], environment: {
        ...Platform.environment,
        'RELAY_ADDR': ':$relayPort',
      });
      addTearDown(relay.kill);
      relay.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => print('[relay] $line'));
      relay.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => print('[relay:err] $line'));
      await _waitUntil(() => _healthy(relayPort));

      // --- 3. Host registration + device pairing on that relay.
      final hostId =
          '88${DateTime.now().millisecondsSinceEpoch.toString().substring(2)}';
      final hostWs = WebSocketChannel.connect(
        Uri.parse('ws://127.0.0.1:$relayPort/relay/v1/host'),
      );
      await hostWs.ready;
      addTearDown(hostWs.sink.close);
      final registered = Completer<void>();
      hostWs.stream.listen((raw) {
        final frame = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
        if (frame['kind'] == 'registered' && !registered.isCompleted) {
          registered.complete();
        }
      });
      hostWs.sink.add(jsonEncode({
        'v': 1,
        'type': 'control',
        'kind': 'register',
        'body': {
          'hostId': hostId,
          'hostName': 'tunnel-e2e',
          'dshVersion': 'test',
          'pin': _pin,
        },
      }));
      await registered.future.timeout(const Duration(seconds: 5));

      final pairBody = await HttpClient()
          .postUrl(Uri.parse('http://127.0.0.1:$relayPort/relay/v1/pair'))
          .then((req) {
            req.headers.contentType = ContentType.json;
            req.write(jsonEncode({'deviceId': hostId, 'pin': _pin}));
            return req.close();
          })
          .then((resp) => resp.transform(utf8.decoder).join());
      final sessionToken =
          (jsonDecode(pairBody) as Map)['sessionToken'] as String;
      expect(sessionToken, isNotEmpty);

      // --- 4. Real bridge (node) wiring the relay to the fake dsh port.
      final lanPort = await _freePort();
      final bridge = await Process.start(
        'node',
        [
          'bridge.mjs',
          '--relay',
          'http://127.0.0.1:$relayPort',
          '--dsh-port',
          '${dsh.port}',
          '--device-id',
          hostId,
          '--pin',
          _pin,
          '--e2e-secret',
          _e2eSecret,
          '--lan-port',
          '$lanPort',
        ],
        workingDirectory: '$mobileRoot/bridge',
      );
      addTearDown(bridge.kill);
      final bridgeUp = Completer<void>();
      bridge.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        print('[bridge] $line');
        if (line.contains('"event":"registered"') && !bridgeUp.isCompleted) {
          bridgeUp.complete();
        }
      });
      bridge.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => print('[bridge:err] $line'));
      await bridgeUp.future.timeout(const Duration(seconds: 10));

      // --- 5. The app side: RelayClient + WebProxy, then drive HTTP through.
      final client = RelayClient(
        relayBase: 'http://127.0.0.1:$relayPort',
        sessionToken: sessionToken,
        e2eSecret: _e2eSecret,
        hostId: hostId,
      );
      addTearDown(client.close);
      await client.connect();

      final proxy = WebProxy(client, remotePort: dsh.port);
      await proxy.start();
      addTearDown(proxy.close);

      final browser = await _Browser.connect(proxy.port);
      addTearDown(browser.destroy);

      // 5a. Launch-token exchange: 303 + Set-Cookie, redirect followed on the
      // SAME connection (keep-alive reuse, like Chromium).
      final mint = await browser.get('/?token=${dsh.launchToken}');
      expect(mint.status, 303, reason: 'token exchange must mint a cookie');
      expect(mint.cookie, isNotNull);

      final index = await browser.get('/');
      expect(index.status, 200, reason: 'cookie must authenticate /');
      expect(index.body, contains('dsh-index'));

      // 5b. API data (the task list).
      final sessions = await browser.get('/api/sessions');
      expect(sessions.status, 200, reason: sessions.body);
      expect(sessions.body, contains('task-a'));

      // 5c. Live updates: SSE events must arrive incrementally, in order.
      final sse = await browser.openStream('/api/events');
      addTearDown(sse.close);
      final first = await sse.nextEvent().timeout(const Duration(seconds: 5));
      final second = await sse.nextEvent().timeout(const Duration(seconds: 5));
      expect([first, second], ['evt-1', 'evt-2'],
          reason: 'SSE events must stream through the tunnel');

      // 5d. New data appears on subsequent API reads.
      dsh.pushSession('task-c');
      final later = await browser.get('/api/sessions');
      expect(later.body, contains('task-c'));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

class _SseStream {
  _SseStream._(this._socket);
  final Socket _socket;
  final _pending = <String>[];
  final _waiters = <Completer<String>>[];
  final _text = StringBuffer();

  /// Opens an SSE request and waits for the response headers; data events are
  /// exposed through [nextEvent].
  static Future<_SseStream> open(int port, String path, String cookie) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 5),
    );
    final status = Completer<int>();
    final stream = _SseStream._(socket);
    final headerBuffer = BytesBuilder();
    late final StreamSubscription<List<int>> subscription;
    subscription = socket.listen(
      (bytes) {
        if (status.isCompleted) {
          stream._ingest(bytes);
          return;
        }
        headerBuffer.add(bytes);
        final buffered = headerBuffer.toBytes();
        final end = _headerEnd(buffered);
        if (end < 0) return;
        final head = utf8.decode(buffered.sublist(0, end));
        final statusLine = head.split('\r\n').first;
        status.complete(int.parse(statusLine.split(' ')[1]));
        final rest = buffered.sublist(end);
        if (rest.isNotEmpty) stream._ingest(rest);
      },
      onDone: () {
        if (!status.isCompleted) status.completeError(StateError('closed'));
      },
      onError: (_) {
        if (!status.isCompleted) status.completeError(StateError('error'));
      },
      cancelOnError: true,
    );
    socket.add(utf8.encode(
      'GET $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:$port\r\n'
      'Cookie: $cookie\r\n'
      'Accept: text/event-stream\r\n\r\n',
    ));
    await status.future.timeout(const Duration(seconds: 5));
    return stream.._subscription = subscription;
  }

  late final StreamSubscription<List<int>> _subscription;

  void _ingest(List<int> bytes) {
    _text.write(utf8.decode(bytes, allowMalformed: true));
    while (true) {
      final text = _text.toString();
      final index = text.indexOf('\n\n');
      if (index < 0) break;
      for (final line in text.substring(0, index).split('\n')) {
        if (line.startsWith('data:')) {
          final event = line.substring(5).trim();
          if (_waiters.isNotEmpty) {
            _waiters.removeAt(0).complete(event);
          } else {
            _pending.add(event);
          }
        }
      }
      _text
        ..clear()
        ..write(text.substring(index + 2));
    }
  }

  Future<String> nextEvent() {
    if (_pending.isNotEmpty) return Future.value(_pending.removeAt(0));
    final waiter = Completer<String>();
    _waiters.add(waiter);
    return waiter.future;
  }

  Future<void> close() async {
    await _subscription.cancel();
    _socket.destroy();
  }
}

class _Response {
  _Response(this.status, this.body, this.cookie);
  final int status;
  final String body;
  final String? cookie;
}

/// Minimal single-connection HTTP client that mimics Chromium keep-alive
/// (sequential requests on one socket).
class _Browser {
  _Browser._(this._socket, this._port);
  final Socket _socket;
  final int _port;
  String? _cookie;
  final _pending = <Completer<_Response>>[];
  final _data = BytesBuilder();

  static Future<_Browser> connect(int port) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 5),
    );
    final browser = _Browser._(socket, port);
    socket.listen(
      browser._onData,
      onDone: () {
        for (final pending in browser._pending) {
          pending.completeError(StateError('connection closed'));
        }
        browser._pending.clear();
      },
      onError: (_) {},
    );
    return browser;
  }

  void _onData(List<int> bytes) {
    print('[browser] +${bytes.length}B ${utf8.decode(bytes, allowMalformed: true).replaceAll('\r\n', '|')}');
    _data.add(bytes);
    final buffered = _data.toBytes();
    final headerEnd = _headerEnd(buffered);
    if (headerEnd < 0) return;
    final head = utf8.decode(buffered.sublist(0, headerEnd));
    final status = int.parse(head.split('\r\n').first.split(' ')[1]);
    final headers = <String, String>{};
    for (final line in head.split('\r\n').skip(1)) {
      final at = line.indexOf(':');
      if (at <= 0) continue;
      headers[line.substring(0, at).trim().toLowerCase()] =
          line.substring(at + 1).trim();
    }
    final remaining = buffered.sublist(headerEnd);
    final chunked = headers['transfer-encoding']?.contains('chunked') == true;
    final List<int> bodyBytes;
    var consumed = remaining.length;
    if (chunked) {
      final decoded = _decodeChunked(remaining);
      if (decoded == null) return; // need more bytes
      bodyBytes = decoded.$1;
      consumed = decoded.$2;
    } else {
      final length = int.tryParse(headers['content-length'] ?? '') ?? 0;
      if (remaining.length < length) return;
      bodyBytes = remaining.sublist(0, length);
      consumed = length;
    }
    _data
      ..clear()
      ..add(remaining.sublist(consumed));

    if (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(_Response(
            status,
            utf8.decode(bodyBytes, allowMalformed: true),
            headers['set-cookie'],
          ));
    }
  }

  Future<_Response> get(String path) async {
    final done = Completer<_Response>();
    _pending.add(done);
    final cookieLine = _cookie == null ? '' : 'Cookie: $_cookie\r\n';
    _socket.add(utf8.encode(
      'GET $path HTTP/1.1\r\n'
      'Host: 127.0.0.1:$_port\r\n'
      '$cookieLine'
      'Accept: text/html,*/*\r\n'
      'Connection: keep-alive\r\n\r\n',
    ));
    final response = await done.future.timeout(const Duration(seconds: 10));
    if (response.cookie != null) _cookie = response.cookie;
    return response;
  }

  Future<_SseStream> openStream(String path) =>
      _SseStream.open(_port, path, _cookie ?? '');

  void destroy() => _socket.destroy();
}

int _headerEnd(List<int> bytes) {
  for (var i = 3; i < bytes.length; i++) {
    if (bytes[i - 3] == 13 &&
        bytes[i - 2] == 10 &&
        bytes[i - 1] == 13 &&
        bytes[i] == 10) {
      return i + 1;
    }
  }
  return -1;
}

/// Decodes a chunked body; returns (decoded, consumed-encoded-bytes), or null
/// when the stream does not yet contain the terminating chunk.
(List<int>, int)? _decodeChunked(List<int> bytes) {
  final out = BytesBuilder();
  var text = utf8.decode(bytes, allowMalformed: true);
  var consumed = 0;
  while (true) {
    final lineEnd = text.indexOf('\r\n');
    if (lineEnd < 0) return null;
    final size = int.tryParse(text.substring(0, lineEnd), radix: 16);
    if (size == null) return null;
    if (size == 0) return (out.toBytes(), consumed + lineEnd + 4);
    final start = lineEnd + 2;
    if (text.length < start + size + 2) return null;
    out.add(utf8.encode(text.substring(start, start + size)));
    text = text.substring(start + size + 2);
    consumed += start + size + 2;
  }
}

/// Fake dsh with the real one's auth shape: launch token → cookie →
/// authenticated index/API, plus an SSE live-update endpoint.
class _FakeDsh {
  _FakeDsh._(this._server, this.port, this.launchToken);
  final HttpServer _server;
  final int port;
  final String launchToken;
  final _sessions = <String>['task-a', 'task-b'];

  static const _cookieName = 'dsh-auth-test';
  static const _cookieValue = 'magic-cookie';

  static Future<_FakeDsh> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dsh = _FakeDsh._(server, server.port, 'tok-${server.port}');
    server.listen(dsh._handle);
    return dsh;
  }

  void pushSession(String id) => _sessions.add(id);

  bool _authorized(HttpRequest req) =>
      req.headers.value(HttpHeaders.cookieHeader)
              ?.contains('$_cookieName=$_cookieValue') ==
      true;

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    // ignore: avoid_print
    print('[dsh] ${req.method} $path auth=${_authorized(req)}');
    if (path == '/' && req.uri.queryParameters['token'] == launchToken) {
      req.response.statusCode = 303;
      req.response.headers
        ..set('location', '/')
        ..set('cache-control', 'no-store')
        ..set('set-cookie', '$_cookieName=$_cookieValue; Path=/; HttpOnly');
      await req.response.close();
      return;
    }
    if (path == '/') {
      if (_authorized(req)) {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>dsh-index</html>');
      } else {
        req.response.statusCode = 401;
        req.response.write('dsh web authentication required\n');
      }
      await req.response.close();
      return;
    }
    if (path == '/api/sessions') {
      if (!_authorized(req)) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'sessions': _sessions}));
      await req.response.close();
      return;
    }
    if (path == '/api/events') {
      if (!_authorized(req)) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      req.response.statusCode = 200;
      req.response.headers
        ..contentType = ContentType('text', 'event-stream')
        ..set('cache-control', 'no-store');
      var seq = 0;
      final timer = Timer.periodic(const Duration(milliseconds: 120), (t) {
        seq += 1;
        req.response.write('data: evt-$seq\n\n');
        if (seq >= 2) {
          t.cancel();
          req.response.close();
        }
      });
      unawaited(req.response.done.then((_) => timer.cancel()));
      return;
    }
    req.response.statusCode = 404;
    await req.response.close();
  }

  void close() => _server.close(force: true);
}

Future<int> _freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<String> _buildRelay(String relayDir) async {
  final cached = File('$relayDir/relay');
  if (!await _hasBin('go')) {
    if (await cached.exists()) return cached.path;
    fail('go toolchain missing and no prebuilt relay binary found');
  }
  final result = await Process.run(
    'go',
    ['build', '-o', 'relay', '.'],
    workingDirectory: relayDir,
  );
  if (result.exitCode != 0) fail('go build relay failed: ${result.stderr}');
  return cached.path;
}

Future<bool> _healthy(int relayPort) async {
  try {
    final resp = await HttpClient()
        .getUrl(Uri.parse('http://127.0.0.1:$relayPort/relay/healthz'))
        .then((req) => req.close())
        .timeout(const Duration(milliseconds: 500));
    await resp.drain<void>();
    return resp.statusCode == 200;
  } catch (_) {
    return false;
  }
}

Future<void> _waitUntil(Future<bool> Function() probe) async {
  for (var i = 0; i < 50; i++) {
    if (await probe()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('relay did not become healthy');
}
