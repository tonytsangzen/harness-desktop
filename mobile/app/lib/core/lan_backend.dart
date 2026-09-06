/// Direct LAN implementation of the opaque port backend.
library;

import 'dart:io';

import 'tunnel_backend.dart';

class LanBackend implements PortBackend {
  LanBackend(this.lan);
  final String lan;

  @override
  Future<PortConnection> connectPort(int port) async {
    final split = lan.lastIndexOf(':');
    final host = split > 0 ? lan.substring(0, split) : lan;
    final exposedPort = split > 0
        ? int.tryParse(lan.substring(split + 1))
        : null;
    if (exposedPort == null) {
      throw const FormatException('invalid LAN endpoint');
    }
    // The LAN bridge exposes one opaque port. The requested dsh port is kept
    // in the interface for parity with the relay backend.
    if (port <= 0) throw const FormatException('invalid port');
    final socket = await Socket.connect(
      host,
      exposedPort,
      timeout: const Duration(seconds: 8),
    );
    return SocketPortConnection(socket);
  }

  void dispose() {}
}
