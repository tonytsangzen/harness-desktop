/// Local TCP endpoint for the WebView.
///
/// Every accepted WebView connection becomes one opaque remote port stream.
/// The proxy only rewrites the initial HTTP Host/Origin headers because the
/// WebView's localhost origin is not the desktop dsh origin. Response bodies,
/// WebSocket upgrades and all application data are otherwise byte-for-byte.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'tunnel_backend.dart';

class WebProxy {
  WebProxy(this.backend, {this.remotePort = 3080});
  final PortBackend backend;
  final int remotePort;
  ServerSocket? _server;
  final Set<Socket> _clients = {};
  final Set<PortConnection> _remotes = {};

  int get port => _server?.port ?? 0;

  Future<void> start() async {
    try {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 38080);
    } catch (_) {
      _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
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
      final remoteSubscription = connection.input.listen(
        client.add,
        onDone: client.destroy,
        onError: (_, __) => client.destroy(),
        cancelOnError: true,
      );
      final requestBuffer = BytesBuilder();
      var requestHeadersDone = false;
      late StreamSubscription<List<int>> clientSubscription;
      clientSubscription = client.listen(
        (bytes) {
          if (requestHeadersDone) {
            connection.add(bytes);
            return;
          }
          requestBuffer.add(bytes);
          final buffered = requestBuffer.toBytes();
          final end = _headerEnd(buffered);
          if (end < 0 && buffered.length < 64 * 1024) return;
          requestHeadersDone = true;
          final rewritten = end >= 0
              ? _rewriteRequest(buffered.sublist(0, end), buffered.sublist(end))
              : buffered;
          connection.add(rewritten);
        },
        onDone: () async {
          await connection.close();
          await remoteSubscription.cancel();
        },
        onError: (_, __) async {
          await connection.close();
          await remoteSubscription.cancel();
        },
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

  static int _headerEnd(List<int> bytes) {
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

  List<int> _rewriteRequest(List<int> header, List<int> rest) {
    var text = utf8.decode(header, allowMalformed: true);
    text = text.replaceFirst(
      RegExp(r'^Host:\s*[^\r\n]*', multiLine: true, caseSensitive: false),
      'Host: 127.0.0.1:$remotePort',
    );
    text = text.replaceAll(
      RegExp(r'^Origin:\s*[^\r\n]*\r\n', multiLine: true, caseSensitive: false),
      '',
    );
    return <int>[...utf8.encode(text), ...rest];
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
}
