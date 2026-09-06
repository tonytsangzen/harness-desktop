/// Opaque byte-port transport used by the WebView proxy.
library;

import 'dart:async';
import 'dart:io';

abstract class PortConnection {
  Stream<List<int>> get input;
  void add(List<int> bytes);
  Future<void> close();
}

abstract class PortBackend {
  Future<PortConnection> connectPort(int port);
}

class SocketPortConnection implements PortConnection {
  SocketPortConnection(this.socket);
  final Socket socket;

  @override
  Stream<List<int>> get input => socket;

  @override
  void add(List<int> bytes) => socket.add(bytes);

  @override
  Future<void> close() => socket.close();
}
