/// App-wide state: pairing, tunnel connection, session list cache.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'dsh_types.dart';
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
  List<SessionSummary> sessions = const [];

  /// Saved pairings (multiple terminals); shown as cards on the home page.
  List<SavedConnection> connections = const [];

  /// The connection the remote view is bound to (for LAN-direct mode).
  SavedConnection? currentConnection;

  /// Last raw session.list reply (truncated) — shown on the sessions page
  /// when the list is empty, for on-device diagnosis.
  String? debugLastReply;

  /// Load saved connections (does not auto-connect).
  Future<void> init() async {
    try {
      final raw = await _storage.read(key: _kConnections);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        connections = list
            .map((e) => SavedConnection.fromJson((e as Map).cast<String, dynamic>()))
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
      await _attach(conn.relay, conn.sessionToken);
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
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
      try {
        final req = await client.getUrl(Uri.parse('http://$lan/'));
        final resp = await req.close().timeout(const Duration(seconds: 1));
        return resp.statusCode == 200;
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
      );
      connections = [
        conn,
        ...connections.where((c) => !(c.relay == relayBase && c.hostId == deviceId)),
      ];
      currentConnection = conn;
      await _saveConnections();
      _log('pair saved connection hostId=$deviceId total=${connections.length}');
      await _attach(relayBase, json['sessionToken'] as String);
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
      );
      connections = [
        updated,
        ...connections.where((c) => !(c.relay == conn.relay && c.hostId == conn.hostId)),
      ];
      currentConnection = updated;
      await _saveConnections();
      _log('repair ok hostId=${conn.hostId}');
      await _attach(conn.relay, json['sessionToken'] as String);
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
      String relayBase, String deviceId, String pin) async {
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
    _log('pair resp status=${resp.statusCode} body=${body.length > 200 ? '${body.substring(0, 200)}…' : body}');
    if (resp.statusCode != 200) {
      String code = 'pair-failed';
      try {
        code = (jsonDecode(body)['error']['code'] as String?) ?? code;
      } catch (_) {}
      throw RelayError(code, body);
    }
    return (jsonDecode(body) as Map).cast<String, dynamic>();
  }

  Future<void> _attach(String relayBase, String token) async {
    final c = RelayClient(relayBase: relayBase, sessionToken: token);
    c.onStatus = (online) {
      _log('tunnel status online=$online');
      connected = online;
      notifyListeners();
      if (online) refreshSessions();
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
    } catch (e) {
      _log('connect error: $e');
      error = '连接失败: $e';
      connected = false;
      // Re-throw so callers (connectTo / pair / repair) can react, e.g. ask
      // for a fresh PIN on RelayError('unauthorized').
      rethrow;
    }
  }

  Future<void> refreshSessions() async {
    final c = client;
    if (c == null) {
      _log('refreshSessions: no client');
      return;
    }
    try {
      final value = await c.rpc('session.list', const {});
      _log('session.list reply keys=${value.keys.toList()} itemsType=${value['items'].runtimeType}');
      final raw = jsonEncode(value);
      _log('session.list reply raw=${raw.length > 400 ? '${raw.substring(0, 400)}…' : raw}');
      // Keep the raw reply (truncated) for on-device diagnosis.
      debugLastReply = raw;
      if (debugLastReply!.length > 600) {
        debugLastReply = '${debugLastReply!.substring(0, 600)}…';
      }
      final items = value['items'] as List? ?? const [];
      _log('session.list items=${items.length} first=${items.isNotEmpty ? jsonEncode(items.first).substring(0, (jsonEncode(items.first).length).clamp(0, 200)) : 'n/a'}');
      sessions = items
          .map((e) => SessionSummary.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _log('session.list parsed sessions=${sessions.length}');
    } catch (e, st) {
      _log('refreshSessions ERROR: $e\n$st');
      error = '会话列表: $e';
    }
    notifyListeners();
  }

  /// Disconnect the current tunnel without removing the saved connection.
  Future<void> disconnect() async {
    client?.close();
    client = null;
    connected = false;
    sessions = const [];
    notifyListeners();
  }

  /// Ask the desktop dsh which session is currently active (running=true).
  /// Returns its id, or null when there is none / on any failure.
  Future<String?> activeSessionId() async {
    final c = client;
    if (c == null) return null;
    try {
      final resp = await c.http('POST', '/api/session.list', headers: {
        'Content-Type': 'application/json',
      }, body: utf8.encode(jsonEncode({
        'type': 'client-request',
        'rpcId': 'mobile-${DateTime.now().millisecondsSinceEpoch}',
        'method': 'session.list',
        'params': <String, dynamic>{},
        'payload': <String, dynamic>{},
      })));
      if (resp.status != 200) return null;
      final data =
          jsonDecode(utf8.decode(base64Decode(resp.bodyB64))) as Map<String, dynamic>;
      final items = (data['result']?['value']?['items'] as List?) ?? const [];
      for (final e in items) {
        if ((e as Map)['running'] == true) return e['sessionId'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
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
  });

  final String relay;
  final String hostId;
  final String sessionToken;
  final String refreshToken;
  final int pairedAt;
  /// Optional "ip:port" of the desktop's dsh web on the LAN (from the QR) —
  /// the phone tries a direct connection first and falls back to the relay.
  final String? lan;

  Map<String, dynamic> toJson() => {
        'relay': relay,
        'hostId': hostId,
        'sessionToken': sessionToken,
        'refreshToken': refreshToken,
        'pairedAt': pairedAt,
        if (lan != null) 'lan': lan,
      };

  factory SavedConnection.fromJson(Map<String, dynamic> json) => SavedConnection(
        relay: json['relay'] as String? ?? '',
        hostId: json['hostId'] as String? ?? '',
        sessionToken: json['sessionToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        pairedAt: (json['pairedAt'] as num?)?.toInt() ?? 0,
        lan: json['lan'] as String?,
      );
}
