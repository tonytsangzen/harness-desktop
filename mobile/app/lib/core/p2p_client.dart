/// WebRTC P2P backend for the phone.
///
/// Same frame protocol as the relay tunnel (`http` / `http-reply` /
/// `sse-open` / `sse-frame` / `sse-close`), but transported over a direct
/// NAT-traversed data channel instead of bouncing through the relay. Signaling
/// (SDP/ICE) is carried by the existing relay tunnel's `signal` frames, so no
/// extra infrastructure is needed. The phone initiates: it creates the data
/// channel and offers; the desktop bridge answers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'relay_client.dart';
import 'tunnel_backend.dart';

class P2pClient implements TunnelBackend {
  P2pClient(this._relay);

  final RelayClient _relay;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  int _seq = 0;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};
  /// Buffers for large `http-reply` bodies split into `http-chunk` frames by
  /// the bridge (WebRTC data channels cap a single message at the negotiated
  /// max-message-size, which plugin bundles exceed).
  final Map<String, _P2PHttpAssembly> _assemblies = {};
  final Map<String, ({void Function(String data) onData, void Function(String? reason)? onClose})>
      _sseHandlers = {};
  final List<void Function()> _unsubs = [];

  bool connected = false;
  String? error;

  /// Fired (once) when the data channel closes unexpectedly — the caller
  /// should fall back to the relay tunnel.
  void Function()? onClosed;

  /// Establish the P2P data channel through the relay's signal frames.
  /// Returns true when the channel is open, false on failure/timeout.
  Future<bool> connect({Duration timeout = const Duration(seconds: 8)}) async {
    final ch = 'sig-${DateTime.now().millisecondsSinceEpoch}-$_seq';
    final dcOpen = Completer<bool>();

    final unsub = _relay.onSignal((f) {
      if (f['channel'] != ch) return;
      final kind = f['kind'];
      final body = (f['body'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (kind == 'p2p-answer') {
        final sdp = body['sdp'] as String?;
        if (sdp != null) _pc?.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      } else if (kind == 'ice') {
        final c = (body['candidate'] as Map?)?.cast<String, dynamic>() ?? const {};
        _pc?.addCandidate(RTCIceCandidate(
          c['candidate'] as String? ?? '',
          c['sdpMid'] as String?,
          (c['sdpMLineIndex'] as num?)?.toInt() ?? 0,
        ));
      } else if (kind == 'p2p-error') {
        error = body['message'] as String?;
        if (!dcOpen.isCompleted) dcOpen.complete(false);
      }
    });
    _unsubs.add(unsub);

    try {
      final pc = await createPeerConnection({
        'iceServers': [
          {'urls': 'stun:stun.l.google.com:19302'},
        ],
      });
      _pc = pc;
      pc.onIceCandidate = (c) {
        _relay.sendSignal(ch, 'ice', {'candidate': c.toMap()});
      };
      final dc = await pc.createDataChannel('dsh', RTCDataChannelInit());
      _dc = dc;
      dc.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          connected = true;
          if (!dcOpen.isCompleted) dcOpen.complete(true);
        } else if (s == RTCDataChannelState.RTCDataChannelClosed) {
          connected = false;
          onClosed?.call();
        }
      };
      dc.onMessage = (msg) => _onFrame(msg.text);
      final offer = await pc.createOffer({
        // flutter_webrtc defaults OfferToReceiveAudio/Video to true, which
        // makes libwebrtc generate audio/video m-lines that werift's single
        // data component can't negotiate. Disable them: only the data
        // channel m-line remains, exactly like a plain browser offer.
        'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
        'optional': <Map<String, dynamic>>[],
      });
      await pc.setLocalDescription(offer);
      _relay.sendSignal(ch, 'p2p-offer', {'sdp': offer.sdp});
      final ok = await dcOpen.future.timeout(timeout, onTimeout: () => false);
      return ok;
    } catch (e) {
      error = '$e';
      return false;
    }
  }

  void dispose() {
    for (final u in _unsubs) {
      u();
    }
    _unsubs.clear();
    _pending.clear();
    _assemblies.clear();
    _sseHandlers.clear();
    try {
      _dc?.close();
    } catch (_) {}
    try {
      _pc?.close();
    } catch (_) {}
    _dc = null;
    _pc = null;
    connected = false;
  }

  /// One HTTP request over the data channel (same shape as RelayClient.http).
  Future<({int status, Map<String, String> headers, String bodyB64})> http(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    final id = 'p2p-${_seq++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _dc?.send(RTCDataChannelMessage(jsonEncode({
      'type': 'http',
      'id': id,
      'method': method,
      'path': path,
      'headers': headers ?? const {},
      'body': (body == null || body.isEmpty) ? '' : base64Encode(body),
    })));
    try {
      final r = await completer.future.timeout(const Duration(seconds: 30));
      // New bridge: body = {headers, body}; old bridge: body = base64 string
      // with headers at the top level. Tolerate both.
      final rawBody = r['body'];
      final Map<String, dynamic> bodyMap;
      if (rawBody is Map) {
        bodyMap = rawBody.cast<String, dynamic>();
      } else if (rawBody is String) {
        bodyMap = {'body': rawBody};
      } else {
        bodyMap = const {};
      }
      final h = (r['headers'] as Map?)?.cast<String, String>() ??
          (bodyMap['headers'] as Map?)?.cast<String, String>() ??
          const <String, String>{};
      return (
        status: r['status'] as int? ?? 502,
        headers: h,
        bodyB64: bodyMap['body'] as String? ?? '',
      );
    } catch (_) {
      _pending.remove(id);
      _assemblies.remove(id);
      return (
        status: 502,
        headers: const <String, String>{},
        bodyB64: '',
      );
    }
  }

  /// Mirror a WebView WebSocket onto the data channel (same as
  /// RelayClient.openSseRaw). Returns the channel id.
  String openSseRaw(
    String path, {
    required void Function(String data) onData,
    void Function(String? reason)? onClose,
  }) {
    final ch = 'ch-${_seq++}';
    _sseHandlers[ch] = (onData: onData, onClose: onClose);
    _dc?.send(RTCDataChannelMessage(jsonEncode({
      'type': 'sse-open',
      'channel': ch,
      'path': path,
      'body': {'raw': true},
    })));
    return ch;
  }

  void closeSse(String channel) {
    _sseHandlers.remove(channel);
    _dc?.send(RTCDataChannelMessage(jsonEncode({'type': 'sse-close', 'channel': channel})));
  }

  void _onFrame(String text) {
    final Map<String, dynamic> f;
    try {
      f = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (f['type']) {
      case 'http-reply':
        _onHttpReply(f);
        break;
      case 'http-chunk':
        _onHttpChunk(f);
        break;
      case 'sse-frame':
        final ch = f['channel'] as String?;
        final data = f['data'] as String?;
        if (ch != null && data != null) _sseHandlers[ch]?.onData(data);
        break;
      case 'sse-close':
        final ch = f['channel'] as String?;
        if (ch != null) {
          _sseHandlers.remove(ch)?.onClose?.call(null);
        }
        break;
      default:
        break;
    }
  }

  /// Handle an `http-reply` frame. A `chunked` reply only carries the status
  /// and headers; its body arrives as subsequent `http-chunk` frames that
  /// [_onHttpChunk] reassembles. Non-chunked replies complete immediately.
  void _onHttpReply(Map<String, dynamic> f) {
    final id = f['id'] as String?;
    if (id == null) return;
    if (f['chunked'] == true) {
      final total = (f['total'] as num?)?.toInt() ?? 0;
      final bodyMap = (f['body'] as Map?)?.cast<String, dynamic>() ?? const {};
      final headers = (bodyMap['headers'] as Map?)?.cast<String, String>() ?? const {};
      if (total <= 1) {
        // Degenerate: nothing to wait for — finish with whatever body we have.
        final c = _pending.remove(id);
        if (c != null && !c.isCompleted) {
          c.complete({
            'status': f['status'] as int? ?? 502,
            'body': {'headers': headers, 'body': (bodyMap['body'] as String?) ?? ''},
          });
        }
        return;
      }
      _assemblies[id] = _P2PHttpAssembly(
        status: f['status'] as int? ?? 502,
        headers: headers,
        total: total,
      );
      return;
    }
    final c = _pending.remove(id);
    if (c != null && !c.isCompleted) c.complete(f);
  }

  void _onHttpChunk(Map<String, dynamic> f) {
    final id = f['id'] as String?;
    final a = id == null ? null : _assemblies[id];
    if (a == null) return;
    final index = (f['index'] as num?)?.toInt() ?? -1;
    final data = f['data'] as String? ?? '';
    if (index < 0 || index >= a.total || a.parts[index] != null) return;
    a.parts[index] = data;
    a.received++;
    if (a.received == a.total) {
      _assemblies.remove(id);
      final c = _pending.remove(id);
      if (c != null && !c.isCompleted) {
        c.complete({
          'status': a.status,
          'body': {'headers': a.headers, 'body': a.parts.join()},
        });
      }
    }
  }
}

/// Reassembly buffer for one chunked `http-reply` over the P2P data channel.
class _P2PHttpAssembly {
  _P2PHttpAssembly({
    required this.status,
    required this.headers,
    required this.total,
  }) : parts = List<String?>.filled(total, null);

  final int status;
  final Map<String, String> headers;
  final int total;
  final List<String?> parts;
  int received = 0;
}
