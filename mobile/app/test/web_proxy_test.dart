/// Tests for the local WebView TCP endpoint: byte transparency with the
/// two HTTP-level accommodations (Accept-Encoding rewrite and polyfill
/// injection into text/html responses).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_mobile/core/tunnel_backend.dart';
import 'package:dsh_mobile/core/web_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeConnection implements PortConnection {
  final StreamController<List<int>> _input = StreamController<List<int>>();
  final List<List<int>> writes = [];
  bool closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void add(List<int> bytes) => writes.add(List<int>.from(bytes));

  void remoteAdd(List<int> bytes) => _input.add(List<int>.from(bytes));

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _input.close();
  }
}

class FakeBackend implements PortBackend {
  FakeBackend(this.expectedPort);
  final int expectedPort;
  final List<FakeConnection> connections = [];

  @override
  Future<PortConnection> connectPort(int port) async {
    expect(port, expectedPort);
    final connection = FakeConnection();
    connections.add(connection);
    return connection;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

class _Response {
  _Response(this.status, this.headers, this.body);
  final int status;
  final Map<String, String> headers;
  final List<int> body;

  String get bodyText => utf8.decode(body, allowMalformed: true);
}

class _Reader {
  final received = <int>[];
  final done = Completer<void>();
}

_Reader startReader(Socket socket) {
  final reader = _Reader();
  socket.listen(
    reader.received.addAll,
    onDone: () {
      if (!reader.done.isCompleted) reader.done.complete();
    },
    onError: (_) {
      if (!reader.done.isCompleted) reader.done.complete();
    },
  );
  return reader;
}

/// One-shot request/response over one socket: sends [request], then closes
/// the remote stream and reads until the socket finishes.
Future<_Response> roundTrip(
  _Reader reader,
  FakeConnection connection,
  Socket socket,
  String request,
  List<int> response,
) async {
  socket.add(utf8.encode(request));
  await settle();
  connection.remoteAdd(response);
  // Let the proxy forward the response and the socket flush it before the
  // stream close triggers the proxy to destroy the client socket.
  await settle();
  await settle();
  await connection.close();
  await reader.done.future.timeout(const Duration(seconds: 2));
  return _parseResponse(reader.received);
}

_Response _parseResponse(List<int> bytes) {
  final headEnd = _headEnd(bytes);
  expect(headEnd, greaterThan(0),
      reason: utf8.decode(bytes, allowMalformed: true));
  final head = utf8.decode(bytes.sublist(0, headEnd));
  final lines = head.split('\r\n');
  final status = int.parse(lines.first.split(' ')[1]);
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final at = line.indexOf(':');
    if (at <= 0) continue;
    headers[line.substring(0, at).trim().toLowerCase()] =
        line.substring(at + 1).trim();
  }
  final rest = bytes.sublist(headEnd);
  final List<int> body;
  if (headers['transfer-encoding']?.contains('chunked') == true) {
    body = _decodeChunked(rest);
  } else {
    final length = int.tryParse(headers['content-length'] ?? '') ?? 0;
    body = rest.sublist(0, length);
  }
  return _Response(status, headers, body);
}

int _headEnd(List<int> bytes) {
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

List<int> _decodeChunked(List<int> bytes) {
  final out = BytesBuilder();
  var text = utf8.decode(bytes, allowMalformed: true);
  while (true) {
    final lineEnd = text.indexOf('\r\n');
    if (lineEnd < 0) break;
    final size = int.tryParse(text.substring(0, lineEnd), radix: 16);
    if (size == null || size == 0) break;
    final start = lineEnd + 2;
    if (text.length < start + size) break;
    out.add(utf8.encode(text.substring(start, start + size)));
    text = text.substring(start + size + 2);
  }
  return out.toBytes();
}

/// A GET request with the Accept-Encoding header the proxy is expected to
/// add, so upstream byte-for-byte assertions stay simple.
String getRequest(String path, {Map<String, String> headers = const {}}) {
  final out = <String>[
    'GET $path HTTP/1.1',
    'Host: 127.0.0.1:38080',
    'Accept-Encoding: identity',
    ...headers.keys.map((k) => '$k: ${headers[k]}'),
    '', '',
  ];
  return out.join('\r\n');
}

Future<(WebProxy, FakeBackend)> startProxy({int remotePort = 3080}) async {
  final backend = FakeBackend(remotePort);
  final proxy = WebProxy(backend, remotePort: remotePort);
  await proxy.start();
  return (proxy, backend);
}

/// Wait until the proxy dialed the backend for the connected socket.
Future<FakeConnection> connectedStream(
  FakeBackend backend,
  Socket socket,
) async {
  while (backend.connections.isEmpty) {
    await settle();
  }
  return backend.connections.single;
}

void main() {
  test('injects the polyfill into content-length HTML and forces no-store',
      () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );
    final reader = startReader(socket);

    final body = utf8.encode(
      '<html><head><title>t</title></head><body>dsh-index</body></html>',
    );
    final response = await roundTrip(
      reader,
      await connectedStream(backend, socket),
      socket,
      getRequest('/'),
      [
        ...utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          'Content-Length: ${body.length}\r\n\r\n',
        ),
        ...body,
      ],
    );

    expect(response.status, 200);
    expect(response.headers['cache-control'], 'no-store');
    expect(response.headers['content-length'], '${response.body.length}');
    final text = response.bodyText;
    final headClose = text.indexOf('<head>') + '<head>'.length;
    expect(text.substring(headClose, headClose + 8), '<script>',
        reason: 'polyfill must be injected right after <head>');
    expect(text, contains('Promise.withResolvers'));
    expect(text, contains('dsh-index'));
  });

  test('injects into chunked HTML and keeps the framing valid', () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );
    final reader = startReader(socket);

    final chunk1 = utf8.encode('<html><head><meta charset="utf-8">');
    final chunk2 = utf8.encode('</head><body>dsh-index</body></html>');
    final response = await roundTrip(
      reader,
      await connectedStream(backend, socket),
      socket,
      getRequest('/'),
      [
        ...utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/html\r\n'
          'Transfer-Encoding: chunked\r\n\r\n',
        ),
        ...utf8.encode('${chunk1.length.toRadixString(16)}\r\n'),
        ...chunk1,
        ...utf8.encode('\r\n${chunk2.length.toRadixString(16)}\r\n'),
        ...chunk2,
        ...utf8.encode('\r\n0\r\n\r\n'),
      ],
    );

    expect(response.status, 200);
    expect(response.headers['cache-control'], 'no-store');
    final text = response.bodyText;
    // ignore: avoid_print
    print('[chunked-test] << ${utf8.decode(reader.received, allowMalformed: true).replaceAll('\r\n', '|')}');
    expect(text, contains('Promise.withResolvers'));
    final headClose = text.indexOf('<head>') + '<head>'.length;
    expect(text.substring(headClose, headClose + 8), '<script>');
    expect(text.indexOf('<meta charset="utf-8">'), greaterThan(headClose));
    expect(text.endsWith('</html>'), isTrue);
  });

  test('never touches JavaScript bundles even when they mention <head>',
      () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );
    final reader = startReader(socket);

    final body = utf8.encode(
      'module.exports = "<head><html>"; // plugin bundle bytes',
    );
    final response = await roundTrip(
      reader,
      await connectedStream(backend, socket),
      socket,
      getRequest('/plugins/bundle.js'),
      [
        ...utf8.encode(
          'HTTP/1.1 200 OK\r\n'
          'Content-Type: application/javascript\r\n'
          'Content-Length: ${body.length}\r\n\r\n',
        ),
        ...body,
      ],
    );

    expect(response.body, body, reason: 'bundles must stay byte-for-byte');
    expect(response.headers['cache-control'], isNull);
  });

  test('skips injection for non-200 and gzipped HTML responses', () async {
    final cases = [
      (
        '401 text/html',
        'HTTP/1.1 401 Unauthorized\r\nContent-Type: text/html\r\n'
            'Content-Length: 9\r\n\r\n',
        utf8.encode('denied!!!'),
      ),
      (
        'gzipped html',
        'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n'
            'Content-Encoding: gzip\r\nContent-Length: 4\r\n\r\n',
        <int>[1, 2, 3, 4],
      ),
    ];
    for (final testCase in cases) {
      final (proxy, backend) = await startProxy();
      addTearDown(proxy.close);
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.port,
      );
      final reader = startReader(socket);
      final response = await roundTrip(
        reader,
        await connectedStream(backend, socket),
        socket,
        getRequest('/'),
        [...utf8.encode(testCase.$2), ...testCase.$3],
      );
      expect(response.body, testCase.$3, reason: 'case ${testCase.$1}');
    }
  });

  test('rewrites every request head on a keep-alive connection', () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );

    // Two requests on one connection; the second is the browser following
    // dsh's 303 redirect after minting the cookie. The client sends gzip in
    // Accept-Encoding and the proxy must replace it with identity.
    final raw = [
      'GET /?token=abc HTTP/1.1\r\n'
          'Host: 127.0.0.1:38080\r\n'
          'Accept-Encoding: gzip, deflate\r\n\r\n',
      'GET / HTTP/1.1\r\n'
          'Host: 127.0.0.1:38080\r\n'
          'Cookie: dsh-auth-x=secret\r\n\r\n',
    ];
    socket.add(utf8.encode(raw[0]));
    await settle();
    socket.add(utf8.encode(raw[1]));
    await settle();

    expect(backend.connections, hasLength(1));
    final writes = backend.connections.single.writes;
    expect(writes, hasLength(2));
    expect(utf8.decode(writes[0]), contains('Accept-Encoding: identity'));
    expect(utf8.decode(writes[0]), isNot(contains('gzip')));
    expect(utf8.decode(writes[1]), contains('Accept-Encoding: identity'));
    expect(utf8.decode(writes[1]), contains('Cookie: dsh-auth-x=secret'));
    socket.destroy();
  });

  test('both HTML responses on a keep-alive connection get injected',
      () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );

    String html(String marker) {
      final body =
          '<html><head></head><body>$marker</body></html>';
      return 'HTTP/1.1 200 OK\r\n'
          'Content-Type: text/html\r\n'
          'Content-Length: ${utf8.encode(body).length}\r\n\r\n'
          '$body';
    }

    final responses = <int>[];
    final allDone = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = socket.listen(responses.addAll, onDone: () {
      if (!allDone.isCompleted) allDone.complete();
    });
    socket.add(utf8.encode(getRequest('/first')));
    await settle();
    backend.connections.single.remoteAdd(utf8.encode(html('one')));
    await settle();
    socket.add(utf8.encode(getRequest('/second')));
    await settle();
    backend.connections.single.remoteAdd(utf8.encode(html('two')));
    await settle();
    await backend.connections.single.close();
    await allDone.future.timeout(const Duration(seconds: 2));
    await sub.cancel();

    final text = utf8.decode(responses, allowMalformed: true);
    expect('one'.allMatches(text).length, 1);
    expect('two'.allMatches(text).length, 1);
    expect(RegExp('<script>').allMatches(text).length, 2,
        reason: 'both HTML documents carry the polyfill');
  });

  test('streams SSE responses through untouched', () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );

    final reader = startReader(socket);
    socket.add(utf8.encode(getRequest('/api/events')));
    await settle();
    backend.connections.single.remoteAdd(utf8.encode(
      'HTTP/1.1 200 OK\r\n'
      'Content-Type: text/event-stream\r\n'
      'Transfer-Encoding: chunked\r\n\r\n'
      'c\r\ndata: evt-1\n\n\r\n',
    ));
    while (!utf8.decode(reader.received, allowMalformed: true)
        .contains('evt-1')) {
      await settle();
    }
    final headAndEvent = utf8.decode(reader.received, allowMalformed: true);
    expect(headAndEvent, contains('text/event-stream'));
    expect(headAndEvent, isNot(contains('<script>')),
        reason: 'SSE bodies must never be modified');
    socket.destroy();
  });

  test('goes fully transparent after a WebSocket upgrade', () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );

    socket.add(utf8.encode(
      'GET /api/ws HTTP/1.1\r\n'
      'Host: 127.0.0.1:38080\r\n'
      'Upgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Accept-Encoding: gzip\r\n'
      'Sec-WebSocket-Key: x\r\n\r\n',
    ));
    await settle();
    // Upstream request keeps the upgrade but drops gzip.
    final upstream =
        utf8.decode(backend.connections.single.writes.first);
    expect(upstream, contains('Upgrade: websocket'));
    expect(upstream, contains('Accept-Encoding: identity'));
    expect(upstream, isNot(contains('gzip')));

    // Raw frames must flow byte-for-byte in both directions post-upgrade.
    final rawUp = [0x81, 0x03, 0x61, 0x62, 0x63];
    final rawDown = [0x82, 0x02, 0x01, 0x02];
    backend.connections.single.remoteAdd(rawDown);
    socket.add(rawUp);
    await settle();

    final writes = backend.connections.single.writes;
    // ignore: avoid_print
    print('[ws] writeCount=${writes.length} sizes=${writes.map((w) => w.length).toList()}');
    expect(writes.last, rawUp,
        reason: 'post-upgrade bytes must be transparent');
    expect(writes.first, utf8.encode(upstream));
    socket.destroy();
  });

  test('each WebView TCP connection gets an independent remote stream',
      () async {
    final (proxy, backend) = await startProxy();
    addTearDown(proxy.close);

    final first = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );
    final second = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.port,
    );
    first.add(utf8.encode(getRequest('/one')));
    second.add(utf8.encode(getRequest('/two')));
    await settle();

    expect(backend.connections, hasLength(2));
    expect(utf8.decode(backend.connections[0].writes.single),
        contains('GET /one'));
    expect(utf8.decode(backend.connections[1].writes.single),
        contains('GET /two'));
    first.destroy();
    second.destroy();
  });

  test('binds the remote dsh port so the WebView origin matches the desktop',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final remotePort = server.port;
    await server.close();
    final (proxy, backend) = await startProxy(remotePort: remotePort);
    addTearDown(proxy.close);
    expect(proxy.port, remotePort);
  });

  test('falls back to another local port when the dsh port is taken',
      () async {
    final occupied = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(occupied.close);
    final backend = FakeBackend(occupied.port);
    final proxy = WebProxy(backend, remotePort: occupied.port);
    await proxy.start();
    addTearDown(proxy.close);
    expect(proxy.port, isNot(occupied.port));
  });
}
