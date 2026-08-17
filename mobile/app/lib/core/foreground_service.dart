/// Foreground-service bridge: keeps the tunnel (LAN proxy / P2P / relay)
/// alive when the UI goes to the background. On Android this raises the
/// process priority so OEM battery savers don't kill the app mid-session.
///
/// Start it once a remote session connects; stop it when the session closes
/// or the app is destroyed. All calls are best-effort (no-ops elsewhere).
library;

import 'package:flutter/services.dart';

class ForegroundService {
  static const MethodChannel _channel = MethodChannel('dsh_mobile/connection');

  static Future<void> start() async {
    try {
      await _channel.invokeMethod('start');
    } catch (_) {
      // Non-Android platforms / missing handler: ignore.
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }
}
