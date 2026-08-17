/// Backend abstraction for the WebView proxy: either the relay tunnel
/// ([RelayClient]) or a direct WebRTC data channel ([P2pClient]). Both speak
/// the same frame protocol, so the proxy is backend-agnostic.
library;


abstract class TunnelBackend {
  Future<({int status, Map<String, String> headers, String bodyB64})> http(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  });

  String openSseRaw(
    String path, {
    required void Function(String data) onData,
    void Function(String? reason)? onClose,
  });

  void closeSse(String channel);
}
