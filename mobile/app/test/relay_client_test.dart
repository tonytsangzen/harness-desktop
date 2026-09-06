/// Unit tests for the device-side opaque port tunnel.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

class FakeChannel with StreamChannelMixin<dynamic> {
  FakeChannel() {
    _outController.stream.listen((data) {
      sent.add(jsonDecode(data as String) as Map<String, dynamic>);
    });
  }

  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final StreamController<dynamic> _outController =
      StreamController<dynamic>.broadcast();
  final List<Map<String, dynamic>> sent = [];

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  StreamSink<dynamic> get sink => _outController.sink;

  void server(Map<String, dynamic> frame) => _controller.add(jsonEncode(frame));

  Future<void> close() async {
    await _controller.close();
    await _outController.close();
  }
}

RelayClient makeClient(FakeChannel channel) => RelayClient(
  relayBase: 'https://relay.example.com',
  sessionToken: 'st_test',
  connector: (uri, {headers}) {
    expect(uri.toString(), 'wss://relay.example.com/relay/v1/device');
    expect(headers?['Authorization'], 'Bearer st_test');
    return channel;
  },
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('connect sends a ping and answers relay ping with pong', () async {
    final channel = FakeChannel();
    final client = makeClient(channel);
    await client.connect();
    expect(channel.sent.first['type'], 'ping');

    channel.server({'v': 1, 'type': 'ping'});
    await settle();
    expect(channel.sent.any((frame) => frame['type'] == 'pong'), isTrue);
    client.close();
    await channel.close();
  });

  test('connectPort forwards opaque bytes in both directions', () async {
    final channel = FakeChannel();
    final client = makeClient(channel);
    await client.connect();
    final connection = await client.connectPort(3080);
    await settle();

    final open = channel.sent.firstWhere(
      (frame) => frame['type'] == 'stream-open',
    );
    expect(open['port'], 3080);
    final streamId = open['streamId'] as String;

    final received = <List<int>>[];
    final subscription = connection.input.listen(received.add);
    final remoteBytes = <int>[0, 1, 2, 127, 128, 254, 255];
    channel.server({
      'v': 1,
      'type': 'stream-data',
      'streamId': streamId,
      'data': base64Encode(remoteBytes),
    });
    await settle();
    expect(received, [remoteBytes]);

    final localBytes = <int>[255, 0, 13, 10, 42];
    connection.add(localBytes);
    await settle();
    final data = channel.sent.lastWhere(
      (frame) => frame['type'] == 'stream-data',
    );
    expect(data['streamId'], streamId);
    expect(base64Decode(data['data'] as String), localBytes);

    await connection.close();
    await settle();
    final close = channel.sent.lastWhere(
      (frame) => frame['type'] == 'stream-close',
    );
    expect(close['streamId'], streamId);
    await subscription.cancel();
    client.close();
    await channel.close();
  });

  test('relay stream-close completes the corresponding input stream', () async {
    final channel = FakeChannel();
    final client = makeClient(channel);
    await client.connect();
    final connection = await client.connectPort(3080);
    await settle();
    final streamId = channel.sent.firstWhere(
      (frame) => frame['type'] == 'stream-open',
    )['streamId'];

    var done = false;
    final subscription = connection.input.listen(
      (_) {},
      onDone: () => done = true,
    );
    channel.server({'v': 1, 'type': 'stream-close', 'streamId': streamId});
    await settle();
    expect(done, isTrue);
    await subscription.cancel();
    client.close();
    await channel.close();
  });
}
