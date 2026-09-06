/// App-wide state: pairing and tunnel connection.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'relay_client.dart';

class AppState extends ChangeNotifier {
  AppState({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _kConnections = 'connections_v1';

  /// Debug logging visible in `adb logcat -s flutter` on release builds.
  static void _log(String msg) => print('[dsh_mobile] $msg');

  final FlutterSecureStorage _storage;

  RelayClient? client;
  bool connected = false;
  bool busy = false;
  String? error;

  /// Saved pairings (multiple terminals); shown as cards on the home page.
  List<SavedConnection> connections = const [];

  /// The connection the remote view is bound to (for LAN-direct mode).
  SavedConnection? currentConnection;

  /// Auto-reconnect state for the relay tunnel: when the socket drops
  /// (network switch, relay hiccup, Android backgrounding) the tunnel
  /// re-attaches with exponential backoff instead of dying silently.
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;

  /// Load saved connections (does not auto-connect).
  Future<void> init() async {
    try {
      final raw = await _storage.read(key: _kConnections);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        connections =
            list
                .map(
                  (e) => SavedConnection.fromJson(
                    (e as Map).cast<String, dynamic>(),
                  ),
                )
                .toList()
              ..sort((a, b) => b.pairedAt.compareTo(a.pairedAt));
        _log('init: loaded ${connections.length} connections');
      }
    } catch (e) {
      _log('init ERROR: $e');
    }
    notifyListeners();
  }

  Future<void> _saveConnections() async {
    await _storage.write(
      key: _kConnections,
      value: jsonEncode(connections.map((c) => c.toJson()).toList()),
    );
  }

  /// Connect to a previously saved terminal; throws on failure.
  Future<void> connectTo(SavedConnection conn) async {
    busy = true;
    error = null;
    currentConnection = conn;
    notifyListeners();
    try {
      await _attach(conn);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Quick reachability probe for a direct LAN connection ("ip:port" from the
  /// pairing QR). Returns true when the desktop's dsh web answers on the LAN.
  /// Kept short (1s): when the phone is not on the same network this must not
  /// stall the connect flow — the relay path is started in parallel anyway.
  static Future<bool> lanAvailable(String lan) async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        final req = await client.getUrl(Uri.parse('http://$lan/'));
        final resp = await req.close().timeout(const Duration(seconds: 1));
        // Newer dsh deliberately answers unauthenticated root requests with
        // 401 (or 403 before the proxy normalizes Host/Origin). Both prove
        // that the LAN bridge is reachable; the WebProxy sends the dsh token
        // and rewrites the request before the real page load.
        return resp.statusCode == 200 ||
            resp.statusCode == 401 ||
            resp.statusCode == 403;
      } finally {
        client.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Remove a saved connection (not revoked on the relay, just locally).
  Future<void> removeConnection(SavedConnection conn) async {
    connections = connections
        .where((c) => !(c.relay == conn.relay && c.hostId == conn.hostId))
        .toList();
    await _saveConnections();
    notifyListeners();
  }

  /// Pair with a host via relay (POST /relay/v1/pair), persist, connect.
  /// `deviceId` is the 13-digit device ID from the host's QR code (or typed in).
  Future<void> pair({
    required String relayBase,
    required String deviceId,
    required String pin,
    String? lan,
    String? e2eSecret,
    int dshPort = 3080,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final json = await _pairRequest(relayBase, deviceId, pin);
      final conn = SavedConnection(
        relay: relayBase,
        hostId: deviceId,
        sessionToken: json['sessionToken'] as String,
        refreshToken: json['refreshToken'] as String? ?? '',
        pairedAt: DateTime.now().millisecondsSinceEpoch,
        lan: lan,
        e2eSecret: e2eSecret,
        dshPort: dshPort,
      );
      connections = [
        conn,
        ...connections.where(
          (c) => !(c.relay == relayBase && c.hostId == deviceId),
        ),
      ];
      currentConnection = conn;
      await _saveConnections();
      _log(
        'pair saved connection hostId=$deviceId total=${connections.length}',
      );
      await _attach(conn);
    } catch (e) {
      _log('pair FAILED: $e');
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Re-pair an existing connection whose token expired: ask for the current
  /// PIN, POST /pair again, update the saved token and reconnect.
  Future<void> repairConnection(SavedConnection conn, String pin) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final json = await _pairRequest(conn.relay, conn.hostId, pin);
      final updated = SavedConnection(
        relay: conn.relay,
        hostId: conn.hostId,
        sessionToken: json['sessionToken'] as String,
        refreshToken: json['refreshToken'] as String? ?? '',
        pairedAt: DateTime.now().millisecondsSinceEpoch,
        lan: conn.lan,
        e2eSecret: conn.e2eSecret,
        dshPort: conn.dshPort,
      );
      connections = [
        updated,
        ...connections.where(
          (c) => !(c.relay == conn.relay && c.hostId == conn.hostId),
        ),
      ];
      currentConnection = updated;
      await _saveConnections();
      _log('repair ok hostId=${conn.hostId}');
      await _attach(updated);
    } catch (e) {
      _log('repair FAILED: $e');
      rethrow;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// POST /relay/v1/pair; returns the parsed JSON body. Throws RelayError on
  /// non-200 (pair-invalid / pair-locked / pair-expired / relay unreachable).
  Future<Map<String, dynamic>> _pairRequest(
    String relayBase,
    String deviceId,
    String pin,
  ) async {
    final uri = Uri.parse('$relayBase/relay/v1/pair');
    _log('pair POST $uri deviceId=$deviceId');
    final resp = await HttpClient()
        .postUrl(uri)
        .then((req) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode({'deviceId': deviceId, 'pin': pin}));
          return req.close();
        })
        .timeout(const Duration(seconds: 15));
    final body = await resp.transform(utf8.decoder).join();
    _log(
      'pair resp status=${resp.statusCode} body=${body.length > 200 ? '${body.substring(0, 200)}…' : body}',
    );
    if (resp.statusCode != 200) {
      String code = 'pair-failed';
      try {
        code = (jsonDecode(body)['error']['code'] as String?) ?? code;
      } catch (_) {}
      throw RelayError(code, body);
    }
    return (jsonDecode(body) as Map).cast<String, dynamic>();
  }

  Future<void> _attach(SavedConnection conn) async {
    _closing = false;
    // Drop the previous tunnel first: reconnects swap in a fresh client and
    // the old WSS socket (zombie after a screen-lock drop) must not leak.
    client?.close();
    client = null;
    final c = RelayClient(
      relayBase: conn.relay,
      sessionToken: conn.sessionToken,
      e2eSecret: conn.e2eSecret,
      hostId: conn.hostId,
    );
    c.onStatus = (online) {
      _log('tunnel status online=$online');
      connected = online;
      notifyListeners();
      if (online) {
        _reconnectAttempt = 0;
      } else {
        _scheduleReconnect(conn);
      }
    };
    c.onFatal = (msg) {
      _log('tunnel FATAL: $msg');
      error = msg;
      notifyListeners();
    };
    client = c;
    try {
      await c.connect();
      connected = true;
      // The client never reports a successful attach (only disconnects), so
      // without this notification the reconnecting overlay would stay up and
      // the remote view would never rebuild its proxy after a drop.
      notifyListeners();
    } catch (e) {
      _log('connect error: $e');
      error = '连接失败: $e';
      connected = false;
      // Re-throw so callers (connectTo / pair / repair) can react, e.g. ask
      // for a fresh PIN on RelayError('unauthorized').
      rethrow;
    }
  }

  /// App resumed (screen unlocked / returned to foreground): the tunnel may
  /// have died while locked and the backoff timer can still be up to 30s
  /// away — retry immediately with a fresh attempt count.
  void resumeReconnect() {
    if (_closing || connected || currentConnection == null) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    final conn = currentConnection!;
    _log('app resumed: reconnecting now');
    _attach(conn).catchError((Object e) {
      _log('resume reconnect failed: $e');
    });
  }

  /// Disconnect the current tunnel without removing the saved connection.
  Future<void> disconnect() async {
    _closing = true;
    _generation++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectAttempt = 0;
    client?.close();
    client = null;
    connected = false;
    notifyListeners();
  }

  /// Re-attach the relay tunnel after a drop, with exponential backoff
  /// (2s → 4s → 8s → 16s → 30s cap). Only runs while this connection is
  /// still the active one and the user hasn't disconnected.
  /// Bumped whenever the user tears a connection down; pending reconnect
  /// schedules from a torn-down client are invalidated by comparing it.
  int _generation = 0;

  void _scheduleReconnect(SavedConnection conn) {
    if (_reconnectTimer != null || _closing) return;
    // Capture the generation, not the client instance: _attach() replaces
    // `client` before it can fail, so comparing against `c` would cancel the
    // whole chain after one failed attempt — the tunnel then never recovers
    // and the page keeps serving stale data until a manual reconnect.
    final gen = _generation;
    final attempt = _reconnectAttempt++;
    final delay = [2, 4, 8, 16, 30][math.min(attempt, 4)];
    _log('schedule reconnect in ${delay}s (attempt $attempt)');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      _reconnectTimer = null;
      if (_closing || gen != _generation) return;
      _log('reconnecting tunnel…');
      _attach(conn).catchError((Object e) {
        _log('reconnect failed: $e');
        _scheduleReconnect(conn);
      });
    });
  }

  bool _closing = false;
}

/// A saved pairing to one terminal (host) — persisted across launches.
class SavedConnection {
  const SavedConnection({
    required this.relay,
    required this.hostId,
    required this.sessionToken,
    required this.refreshToken,
    required this.pairedAt,
    this.lan,
    this.e2eSecret,
    this.dshPort = 3080,
  });

  final String relay;
  final String hostId;
  final String sessionToken;
  final String refreshToken;
  final int pairedAt;

  /// Optional "ip:port" of the desktop's dsh web on the LAN (from the QR) —
  /// the phone tries a direct connection first and falls back to the relay.
  final String? lan;

  /// End-to-end tunnel secret from the pairing QR (`e2e=`); shared with the
  /// desktop bridge out-of-band so the relay cannot read stream payloads.
  final String? e2eSecret;

  /// Actual dsh port for hosts whose desktop selected a non-default port.
  final int dshPort;

  Map<String, dynamic> toJson() => {
    'relay': relay,
    'hostId': hostId,
    'sessionToken': sessionToken,
    'refreshToken': refreshToken,
    'pairedAt': pairedAt,
    if (lan != null) 'lan': lan,
    if (e2eSecret != null && e2eSecret!.isNotEmpty) 'e2eSecret': e2eSecret,
    'dshPort': dshPort,
  };

  factory SavedConnection.fromJson(Map<String, dynamic> json) =>
      SavedConnection(
        relay: json['relay'] as String? ?? '',
        hostId: json['hostId'] as String? ?? '',
        sessionToken: json['sessionToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        pairedAt: (json['pairedAt'] as num?)?.toInt() ?? 0,
        lan: json['lan'] as String?,
        e2eSecret: json['e2eSecret'] as String?,
        dshPort: (json['dshPort'] as num?)?.toInt() ?? 3080,
      );
}
