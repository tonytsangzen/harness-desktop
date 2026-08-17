/// Unit tests for RelayClient frame protocol and SseFrame parsing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/dsh_types.dart';
import 'package:dsh_mobile/core/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

/// Fake channel: a broadcast stream we push server frames into, recording
/// everything the client sends.
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
  Stream get stream => _controller.stream;

  @override
  StreamSink<dynamic> get sink => _outController.sink;

  void server(Map<String, dynamic> frame) =>
      _controller.add(jsonEncode(frame));
}

RelayClient makeClient(FakeChannel ch) => RelayClient(
      relayBase: 'https://relay.example.com',
      sessionToken: 'st_test',
      connector: (uri, {headers}) {
        expect(uri.toString(), 'wss://relay.example.com/relay/v1/device');
        expect(headers?['Authorization'], 'Bearer st_test');
        return ch;
      },
    );

void main() {
  test('rpc sends proper frame and resolves with result.value', () async {
    final ch = FakeChannel();
    final c = makeClient(ch);
    await c.connect();

    final future = c.rpc('session.list', const {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sent = ch.sent.first;
    expect(sent['type'], 'rpc');
    expect(sent['path'], '/api/session.list');
    expect(sent['body'], const {});

    ch.server({
      'v': 1, 'type': 'rpc-reply',
      'rpcId': sent['rpcId'],
      'body': {'ok': true, 'value': {'items': []}},
    });
    final value = await future;
    expect(value, {'items': []});
  });

  test('rpc error surfaces as RelayError', () async {
    final ch = FakeChannel();
    final c = makeClient(ch);
    await c.connect();

    final future = c.rpc('session.list');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    ch.server({
      'v': 1, 'type': 'rpc-reply', 'rpcId': ch.sent.first['rpcId'],
      'body': {'ok': false, 'error': {'code': 'host-offline'}},
    });
    await expectLater(future, throwsA(isA<RelayError>()));
  });

  test('ping answered with pong', () async {
    final ch = FakeChannel();
    final c = makeClient(ch);
    await c.connect();
    ch.server({'v': 1, 'type': 'ping'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ch.sent.any((f) => f['type'] == 'pong'), isTrue);
  });

  test('sse-open dispatches frames and responds', () async {
    final ch = FakeChannel();
    final c = makeClient(ch);
    await c.connect();

    final frames = <SseFrame>[];
    final chId = c.openSse('/api/events.mux', onFrame: frames.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(ch.sent.first['type'], 'sse-open');
    expect(ch.sent.first['channel'], chId);

    ch.server({
      'v': 1, 'type': 'sse-frame', 'channel': chId,
      'body': {
        'rpcId': 'rpc_ap1', 'method': 'events.mux',
        'payload': {'type': 'approval/requested', 'sessionId': 's1', 'approvalId': 'ap1', 'toolName': 'bash'},
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(frames, hasLength(1));
    expect(frames.first.type, 'approval/requested');
    expect(frames.first.rpcId, 'rpc_ap1');
    expect(frames.first.summary, contains('审批'));

    // Answer it; respond frame echoes the approval rpcId.
    final answer = c.respond('rpc_ap1', {'approvalId': 'ap1', 'outcome': 'approved'});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sent = ch.sent.last;
    expect(sent['type'], 'respond');
    expect(sent['rpcId'], 'rpc_ap1');
    expect(sent['path'], '/api/respond');
    ch.server({
      'v': 1, 'type': 'rpc-reply', 'rpcId': 'rpc_ap1',
      'body': {'ok': true, 'value': {'accepted': true}},
    });
    expect((await answer)['accepted'], isTrue);
  });

  test('SseFrame parsing of jobs and step events', () {
    final jobs = SseFrame.fromJson({
      'rpcId': 'r1', 'method': 'events.mux',
      'payload': {
        'type': 'session/jobs', 'sessionId': 's1',
        'jobs': [
          {'id': 'bash-1', 'kind': 'bash', 'label': 'npm install', 'status': 'running', 'startedAt': 1},
          {'id': 'subagent-2', 'kind': 'subagent', 'label': '调研', 'status': 'completed', 'startedAt': 2, 'finishedAt': 3},
        ],
      },
    });
    expect(jobs.jobs, hasLength(2));
    expect(jobs.jobs.first.isActive, isTrue);
    expect(jobs.summary, contains('1 运行中'));

    final step = SseFrame.fromJson({
      'rpcId': 'r2', 'method': 'events.mux',
      'payload': {
        'type': 'session/event', 'sessionId': 's1',
        'event': {'type': 'step/start', 'seq': 1, 'data': {'turn': 0, 'step': 0}},
      },
    });
    expect(step.eventType, 'step/start');
    expect(step.summary, startsWith('▶'));
  });
}
