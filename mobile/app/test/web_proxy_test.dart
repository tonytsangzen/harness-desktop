/// Integration tests for WebProxy's caching layers: disk persistence across
/// proxy instances, entry-document ETag revalidation (304), request
/// coalescing, and gzip normalization.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/disk_cache.dart';
import 'package:dsh_mobile/core/tunnel_backend.dart';
import 'package:dsh_mobile/core/web_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same record shape TunnelBackend.http returns.
typedef TunnelReply = ({int status, Map<String, String> headers, String bodyB64});

/// Records every tunneled request and answers from a scriptable handler.
class FakeBackend implements TunnelBackend {
  int calls = 0;
  final List<String> seenPaths = [];
  final List<Map<String, String>> seenHeaders = [];
  Future<TunnelReply> Function(FakeBackend backend, String method, String path,
      Map<String, String> headers)? onHttp;

  @override
  Future<TunnelReply> http(String method, String path,
      {Map<String, String>? headers, List<int>? body}) async {
    calls++;
    seenPaths.add(path);
    seenHeaders.add(Map.of(headers ?? const {}));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return onHttp!(this, method, path, headers ?? const {});
  }

  @override
  String openSseRaw(String path,
      {required void Function(String data) onData,
      void Function(String? reason)? onClose}) {
    throw UnimplementedError();
  }

  @override
  void closeSse(String channel) {}
}

Future<HttpClientResponse> get(String url) async {
  final resp = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
  return resp;
}

void main() {
  late Directory dir;
  late DiskCache disk;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dsh_webproxy_test');
    disk = DiskCache.forDir(dir);
  });

  tearDown(() async {
    await disk.flush();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('cacheable asset persists across proxy instances', () async {
    final backend = FakeBackend()
      ..onHttp = (b, m, p, h) async => (
            status: 200,
            headers: {'content-type': 'text/javascript'},
            bodyB64: base64Encode(utf8.encode('bundle()'))
          );

    // First session: fetches through the tunnel.
    final p1 = WebProxy(backend, disk: disk);
    await p1.start();
    final r1 = await get('http://127.0.0.1:${p1.port}/assets/app-abc.js');
    final body1 = await r1.transform(utf8.decoder).join();
    await p1.close();
    expect(body1, 'bundle()');
    expect(backend.calls, 1);

    // Second session (fresh proxy, same disk): served from disk, zero calls.
    final p2 = WebProxy(backend, disk: disk);
    await p2.start();
    final r2 = await get('http://127.0.0.1:${p2.port}/assets/app-abc.js');
    final body2 = await r2.transform(utf8.decoder).join();
    await p2.close();
    expect(body2, 'bundle()');
    expect(backend.calls, 1, reason: 'second session must not hit the tunnel');
  });

  test('entry document revalidates via if-none-match / 304', () async {
    const docBody = '<!doctype html><html><head></head><body></body></html>';
    const etag = '"e1f531b0"';
    var changed = false;
    final backend = FakeBackend()
      ..onHttp = (b, m, p, h) async {
        final inm = h['if-none-match'];
        if (!changed && inm == etag) {
          return (status: 304, headers: {'etag': etag}, bodyB64: '');
        }
        return (
          status: 200,
          headers: {'content-type': 'text/html', 'etag': etag},
          bodyB64: base64Encode(utf8.encode(changed ? 'NEW DOC' : docBody)),
        );
      };

    final p1 = WebProxy(backend, disk: disk);
    await p1.start();
    final r1 = await get('http://127.0.0.1:${p1.port}/');
    final body1 = await r1.transform(utf8.decoder).join();
    await p1.close();
    expect(body1, contains('<!doctype html>'));
    expect(backend.calls, 1);
    expect(backend.seenHeaders[0].containsKey('if-none-match'), isFalse);

    // Unchanged next session: proxy revalidates, tunnel answers 304, the
    // stored body is served as 200.
    final p2 = WebProxy(backend, disk: disk);
    await p2.start();
    final r2 = await get('http://127.0.0.1:${p2.port}/');
    final body2 = await r2.transform(utf8.decoder).join();
    await p2.close();
    expect(backend.calls, 2);
    expect(backend.seenHeaders[1]['if-none-match'], etag);
    expect(r2.statusCode, 200);
    expect(body2, contains('<!doctype html>'));

    // Changed upstream: full 200 body passes through and replaces the record.
    changed = true;
    final p3 = WebProxy(backend, disk: disk);
    await p3.start();
    final r3 = await get('http://127.0.0.1:${p3.port}/');
    final body3 = await r3.transform(utf8.decoder).join();
    await p3.close();
    expect(backend.calls, 3);
    expect(body3, 'NEW DOC');
  });

  test('parallel identical GETs share one tunnel request', () async {
    final backend = FakeBackend()
      ..onHttp = (b, m, p, h) async => (
            status: 200,
            headers: {'content-type': 'text/javascript'},
            bodyB64: base64Encode(utf8.encode('x'))
          );
    final proxy = WebProxy(backend, disk: disk);
    await proxy.start();
    final results = await Future.wait([
      get('http://127.0.0.1:${proxy.port}/assets/par-1.js'),
      get('http://127.0.0.1:${proxy.port}/assets/par-1.js'),
      get('http://127.0.0.1:${proxy.port}/assets/par-1.js'),
    ]);
    await proxy.close();
    for (final r in results) {
      expect(r.statusCode, 200);
    }
    expect(backend.calls, 1, reason: 'coalesced into one tunnel round trip');
  });

  test('gzipped tunnel replies are decoded before serving', () async {
    final gz = GZipCodec().encode(utf8.encode('console.log("gz")'));
    final backend = FakeBackend()
      ..onHttp = (b, m, p, h) async => (
            status: 200,
            headers: {'content-type': 'text/javascript', 'content-encoding': 'gzip'},
            bodyB64: base64Encode(gz),
          );
    final proxy = WebProxy(backend, disk: disk);
    await proxy.start();
    final r = await get('http://127.0.0.1:${proxy.port}/assets/gz-1.js');
    final body = await r.transform(utf8.decoder).join();
    await proxy.close();
    expect(body, 'console.log("gz")');
    expect(r.headers.value('content-encoding'), isNull);
  });
}
