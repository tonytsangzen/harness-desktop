/// Unit tests for the persistent web resource cache (DiskCache).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/disk_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late DiskCache cache;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dsh_diskcache_test');
    cache = DiskCache.forDir(dir);
  });

  tearDown(() async {
    // Settle queued writes first: the atomic index write (tmp -> rename) can
    // otherwise race the recursive delete and blow it up.
    await cache.flush();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('put + get round-trips body, headers and etag', () async {
    await cache.put('/assets/a.js',
        status: 200,
        headers: {'content-type': 'text/javascript'},
        body: utf8.encode('console.log(1)'),
        etag: '"abc"');

    final e = await cache.get('/assets/a.js');
    expect(e, isNotNull);
    expect(utf8.decode(e!.body), 'console.log(1)');
    expect(e.headers['content-type'], 'text/javascript');
    expect(e.etag, '"abc"');
    expect(e.status, 200);
  });

  test('entries persist across cache instances (app restart)', () async {
    await cache.put('/assets/b.js',
        status: 200, headers: {}, body: utf8.encode('x' * 10));

    final reopened = DiskCache.forDir(dir);
    final e = await reopened.get('/assets/b.js');
    expect(e, isNotNull);
    expect(utf8.decode(e!.body), 'x' * 10);
  });

  test('missing url returns null', () async {
    expect(await cache.get('/nope'), isNull);
  });

  test('non-200 and oversized bodies are refused', () async {
    await cache.put('/bad',
        status: 502, headers: {}, body: utf8.encode('error'));
    await cache.put('/empty', status: 200, headers: {}, body: const <int>[]);
    await cache.put('/huge',
        status: 200,
        headers: {},
        body: List<int>.filled(DiskCache.maxEntryBytes + 1, 0));

    expect(await cache.get('/bad'), isNull);
    expect(await cache.get('/empty'), isNull);
    expect(await cache.get('/huge'), isNull);
  });

  test('LRU eviction keeps total under the cap', () async {
    // Tiny cap via many entries is impractical (cap is 64MB) — exercise the
    // eviction path directly by filling with entries that exceed it.
    final chunk = List<int>.filled(1024 * 1024, 65); // 1MB 'A's
    for (var i = 0; i < 70; i++) {
      await cache.put('/assets/f$i.js', status: 200, headers: {}, body: chunk);
    }
    expect(cache.totalBytes, lessThanOrEqualTo(DiskCache.maxTotalBytes));
    // Oldest entries evicted, newest still present.
    expect(await cache.get('/assets/f0.js'), isNull);
    expect(await cache.get('/assets/f69.js'), isNotNull);
  });

  test('corrupt index rebuilds without throwing', () async {
    await cache.put('/assets/c.js',
        status: 200, headers: {}, body: utf8.encode('data'));
    await File('${dir.path}/index.json').writeAsString('{not json');

    final reopened = DiskCache.forDir(dir);
    expect(await reopened.get('/assets/c.js'), isNull); // index reset
    await reopened.put('/assets/d.js',
        status: 200, headers: {}, body: utf8.encode('new'));
    expect((await reopened.get('/assets/d.js'))!, isNotNull);
  });

  test('clear drops all entries and blobs', () async {
    await cache.put('/assets/e.js',
        status: 200, headers: {}, body: utf8.encode('gone'));
    await cache.clear();
    expect(await cache.get('/assets/e.js'), isNull);
    expect(cache.entryCount, 0);
  });
}
