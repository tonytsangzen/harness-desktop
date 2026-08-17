// macOS probe: validates flutter_webrtc (libwebrtc — same engine as Android)
// interoperating with the desktop bridge's werift WebRTC stack over the relay
// signaling channel. Prints progress and exits 0 on success.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const relayBase = 'http://127.0.0.1:8080';
const hostId = String.fromEnvironment('HOST', defaultValue: '8621742451123');
const pin = '123456';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[probe] start');
  try {
    final sessionToken = await _pair();
    debugPrint('[probe] paired');
    final ws = IOWebSocketChannel.connect(
      Uri.parse(relayBase.replaceFirst('http', 'ws') + '/relay/v1/device'),
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    final stream = ws.stream.asBroadcastStream();
    final ok = await _p2p(stream, (frame) => ws.sink.add(jsonEncode(frame)));
    debugPrint('[probe] RESULT: ${ok ? "PASS" : "FAIL"}');
    exit(ok ? 0 : 1);
  } catch (e) {
    debugPrint('[probe] ERROR: $e');
    exit(1);
  }
}

Future<String> _pair() async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('$relayBase/relay/v1/pair'));
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode({'deviceId': hostId, 'pin': pin}));
  final resp = await req.close();
  final body = await resp.transform(utf8.decoder).join();
  client.close();
  final j = jsonDecode(body) as Map<String, dynamic>;
  final t = j['sessionToken'] as String?;
  if (t == null) throw Exception('pair failed: $body');
  return t;
}

Future<bool> _p2p(Stream<dynamic> stream, void Function(Map) send) async {
  const ch = 'sig-probe';
  final pc = await createPeerConnection({
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  }, {
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
  });
  final dc = await pc.createDataChannel('dsh', RTCDataChannelInit());
  pc.onIceConnectionState = (s) => debugPrint('[probe] ice conn state: $s');
  pc.onConnectionState = (s) => debugPrint('[probe] conn state: $s');
  final dcOpen = Completer<bool>();
  dc.onDataChannelState = (s) {
    debugPrint('[probe] dc state: $s');
    if (s == RTCDataChannelState.RTCDataChannelOpen && !dcOpen.isCompleted) {
      dcOpen.complete(true);
    }
  };
  pc.onIceCandidate = (c) {
    debugPrint('[probe] local ice: ${c.toMap()}');
    send({
      'v': 1,
      'type': 'signal',
      'channel': ch,
      'kind': 'ice',
      'body': {'candidate': c.toMap()},
    });
  };
  stream.listen((raw) async {
    final f = jsonDecode(raw as String) as Map<String, dynamic>;
    if (f['type'] != 'signal' || f['channel'] != ch) return;
    final kind = f['kind'];
    final body = (f['body'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (kind == 'p2p-answer') {
      debugPrint('[probe] got answer');
      await pc.setRemoteDescription(
          RTCSessionDescription(body['sdp'] as String? ?? '', 'answer'));
    } else if (kind == 'ice') {
      debugPrint('[probe] remote ice: ${body['candidate']}');
      final c = (body['candidate'] as Map?)?.cast<String, dynamic>() ?? const {};
      await pc.addCandidate(RTCIceCandidate(
        c['candidate'] as String? ?? '',
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt() ?? 0,
      ));
    } else if (kind == 'p2p-error') {
      debugPrint('[probe] host p2p-error: ${body['message']}');
    }
  });
  final offer = await pc.createOffer({
    'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
    'optional': [],
  });
  await pc.setLocalDescription(offer);
  // Reject audio/video m-lines: werift answers a single data component and
  // libwebrtc then skips the rejected components entirely.
  var sdp = offer.sdp ?? '';
  sdp = sdp.replaceAllMapped(RegExp('^m=(audio|video) \\d+', multiLine: true), (m) => 'm=${m.group(1)} 0');
  debugPrint('[probe] offer m-lines after fix: ${(sdp.split('\n').where((l) => l.startsWith('m=')).length)}');
  send({
    'v': 1,
    'type': 'signal',
    'channel': ch,
    'kind': 'p2p-offer',
    'body': {'sdp': sdp},
  });
  debugPrint('[probe] offer sent');
  final opened = await dcOpen.future.timeout(const Duration(seconds: 20), onTimeout: () => false);
  if (!opened) {
    debugPrint('[probe] data channel never opened');
    return false;
  }
  // HTTP roundtrip over the channel.
  final reply = Completer<String>();
  dc.onMessage = (msg) {
    final t = msg.text;
    debugPrint('[probe] dc reply: ${t.substring(0, t.length.clamp(0, 90))}');
    if (!reply.isCompleted) reply.complete(t);
  };
  dc.send(RTCDataChannelMessage(jsonEncode({
    'type': 'http',
    'id': 'probe-1',
    'method': 'GET',
    'path': '/',
    'headers': <String, String>{},
    'body': '',
  })));
  final text = await reply.future.timeout(const Duration(seconds: 20), onTimeout: () => '');
  final ok = text.isNotEmpty && text.contains('http-reply');
  debugPrint('[probe] HTTP roundtrip: ${ok ? "PASS" : "FAIL"}');
  return ok;
}
