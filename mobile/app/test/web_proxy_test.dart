/// Integration tests for the local WebView TCP endpoint.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final List<FakeConnection> connections = [];

  @override
  Future<PortConnection> connectPort(int port) async {
    expect(port, 3080);
    final connection = FakeConnection();
    connections.add(connection);
    return connection;
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  test(
    'forwards TCP bytes and rewrites only initial Host/Origin headers',
    () async {
      final backend = FakeBackend();
      final proxy = WebProxy(backend);
      await proxy.start();
      addTearDown(proxy.close);

      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.port,
      );
      final response = <int>[];
      final responseDone = Completer<void>();
      socket.listen(
        response.addAll,
        onDone: () {
          if (!responseDone.isCompleted) responseDone.complete();
        },
      );

      final request = utf8.encode(
        'GET / HTTP/1.1\r\n'
        'Host: 127.0.0.1:${proxy.port}\r\n'
        'Origin: http://127.0.0.1:${proxy.port}\r\n'
        'Connection: close\r\n\r\n'
        'body-is-transparent',
      );
      socket.add(request);
      await settle();

      expect(backend.connections, hasLength(1));
      final upstreamRequest = utf8.decode(
        backend.connections.single.writes.single,
      );
      expect(upstreamRequest, contains('Host: 127.0.0.1:3080\r\n'));
      expect(upstreamRequest, isNot(contains('Origin:')));
      expect(upstreamRequest, endsWith('body-is-transparent'));

      final remoteResponse = <int>[
        ...utf8.encode('HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n'),
        0,
        255,
        1,
        254,
      ];
      backend.connections.single.remoteAdd(remoteResponse);
      await settle();
      socket.destroy();
      await responseDone.future.timeout(const Duration(seconds: 1));
      expect(response, remoteResponse);
    },
  );

  test(
    'each WebView TCP connection gets an independent remote stream',
    () async {
      final backend = FakeBackend();
      final proxy = WebProxy(backend);
      await proxy.start();
      addTearDown(proxy.close);

      final first = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.port,
      );
      final second = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.port,
      );
      first.add(utf8.encode('GET /one HTTP/1.1\r\nHost: old\r\n\r\n'));
      second.add(utf8.encode('GET /two HTTP/1.1\r\nHost: old\r\n\r\n'));
      await settle();

      expect(backend.connections, hasLength(2));
      expect(
        utf8.decode(backend.connections[0].writes.single),
        contains('GET /one'),
      );
      expect(
        utf8.decode(backend.connections[1].writes.single),
        contains('GET /two'),
      );
      first.destroy();
      second.destroy();
    },
  );
}
