/// Persistent on-disk cache for dsh web resources whose URL carries their
/// content identity: `/assets/<name>-<hash>.js` and `/plugins/**/client.js?rev=<hash>`.
/// The hash in the URL changes whenever the content changes, so a cached entry
/// can never be stale — on a new connection (or app restart) those files are
/// served from disk and never touch the slow relay tunnel again.
///
/// Also stores revalidatable entries (the `/` entry document): the body plus
/// the bridge-issued ETag, so the next connect can ask "changed?" with an
/// If-None-Match and get a 304 instead of re-downloading (see bridge.mjs).
///
/// Storage layout in the cache directory:
///   index.json          — key -> metadata (url, status, headers, etag, size, at)
///   <sha256(url)>.bin   — response body bytes
///
/// Writes are serialized through a queue so interleaved puts can't corrupt
/// index.json; a corrupt index is discarded (the cache rebuilds itself).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One cached response (metadata + body).
class DiskCacheEntry {
  DiskCacheEntry({
    required this.url,
    required this.status,
    required this.headers,
    required this.body,
    this.etag,
    required this.at,
  });

  final String url;
  final int status;
  final Map<String, String> headers;
  final List<int> body;

  /// Bridge-issued ETag of the body (strong, quoted) for revalidation.
  final String? etag;

  /// Last access, milliseconds since epoch (drives LRU eviction).
  int at;

  /// Metadata-only view (body not loaded).
  DiskCacheEntry metaOnly(int size) => DiskCacheEntry(
        url: url,
        status: status,
        headers: headers,
        body: const [],
        etag: etag,
        at: at,
      ).._size = size;

  Map<String, dynamic> toJson() => {
        'url': url,
        'status': status,
        'headers': headers,
        'size': _size > 0 ? _size : body.length,
        if (etag != null) 'etag': etag,
        'at': at,
      };

  int _size = 0;
  int get size => _size > 0 ? _size : body.length;
}

class DiskCache {
  DiskCache._(this._dir);

  /// Shared instance rooted at the OS cache directory. The OS may purge it
  /// under storage pressure — that only costs re-downloads, never correctness.
  static Future<DiskCache> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/dsh_web_cache_v1');
    await dir.create(recursive: true);
    return _instance = DiskCache._(dir);
  }

  static DiskCache? _instance;

  /// Test seam: a cache rooted at an arbitrary (typically temporary) directory.
  factory DiskCache.forDir(Directory dir) => DiskCache._(dir);

  static const int maxTotalBytes = 64 * 1024 * 1024;
  static const int maxEntryBytes = 8 * 1024 * 1024;

  final Directory _dir;
  final Map<String, DiskCacheEntry> _index = {};
  Future<void> _loaded = Future.value();
  Future<void> _writeChain = Future.value();
  int _totalBytes = 0;

  static String keyFor(String url) =>
      sha256.convert(utf8.encode(url)).toString();

  File get _indexFile => File('${_dir.path}/index.json');

  Future<void> _ensureLoaded() {
    // Chain so concurrent first calls don't double-load.
    _loaded = _loaded.then((_) => _loadOnce());
    return _loaded;
  }

  Future<void> _loadOnce() async {
    if (_index.isNotEmpty) return;
    try {
      final raw = await _indexFile.readAsString();
      final decoded = (jsonDecode(raw) as Map?)?.cast<String, dynamic>() ?? {};
      final entries = (decoded['entries'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final e in entries.entries) {
        final json = (e.value as Map).cast<String, dynamic>();
        final meta = DiskCacheEntry(
          url: json['url'] as String? ?? '',
          status: (json['status'] as num?)?.toInt() ?? 200,
          headers: ((json['headers'] as Map?) ?? const {})
              .cast<String, String>(),
          body: const [],
          etag: json['etag'] as String?,
          at: (json['at'] as num?)?.toInt() ?? 0,
        ).metaOnly((json['size'] as num?)?.toInt() ?? 0);
        _index[e.key] = meta;
        _totalBytes += meta.size;
      }
    } catch (_) {
      // Missing or corrupt index: start fresh; orphaned blobs are overwritten
      // by the same keys or evicted.
      _index.clear();
      _totalBytes = 0;
    }
  }

  /// Returns the cached entry with its body, or null. Touches LRU order.
  Future<DiskCacheEntry?> get(String url) async {
    await _ensureLoaded();
    final key = keyFor(url);
    final meta = _index[key];
    if (meta == null) return null;
    try {
      final body = await File('${_dir.path}/$key.bin').readAsBytes();
      meta.at = DateTime.now().millisecondsSinceEpoch;
      _scheduleIndexWrite();
      return DiskCacheEntry(
        url: meta.url,
        status: meta.status,
        headers: meta.headers,
        body: body,
        etag: meta.etag,
        at: meta.at,
      );
    } catch (_) {
      // Blob gone (OS purge, partial write): drop the dangling metadata.
      _totalBytes -= meta.size;
      _index.remove(key);
      _scheduleIndexWrite();
      return null;
    }
  }

  /// Stores a response. Oversized entries and non-200s are refused.
  ///
  /// The whole operation runs inside the serialized write chain, so any
  /// later [get] (whose load step chains the same way) deterministically
  /// sees the entry — even when the caller doesn't await this future.
  Future<void> put(
    String url, {
    required int status,
    required Map<String, String> headers,
    required List<int> body,
    String? etag,
  }) {
    if (status != 200 || body.isEmpty || body.length > maxEntryBytes) {
      return Future.value();
    }
    Future<void> op() async {
      await _ensureLoaded();
      final key = keyFor(url);
      final existing = _index[key];
      if (existing != null) _totalBytes -= existing.size;
      final meta = DiskCacheEntry(
        url: url,
        status: status,
        headers: Map.of(headers),
        body: const [],
        etag: etag,
        at: DateTime.now().millisecondsSinceEpoch,
      ).metaOnly(body.length);
      _index[key] = meta;
      _totalBytes += body.length;
      _evict();
      try {
        await File('${_dir.path}/$key.bin').writeAsBytes(body, flush: true);
        await _writeIndex();
      } catch (_) {
        // Disk full / IO error: pretend it never happened.
        if (identical(_index[key], meta)) {
          _totalBytes -= meta.size;
          _index.remove(key);
        }
      }
    }

    _writeChain = _writeChain.then((_) => op());
    return _writeChain;
  }

  void _evict() {
    while (_totalBytes > maxTotalBytes && _index.length > 1) {
      String? oldestKey;
      int oldest = DateTime.now().millisecondsSinceEpoch + 1;
      for (final e in _index.entries) {
        if (e.value.at < oldest) {
          oldest = e.value.at;
          oldestKey = e.key;
        }
      }
      if (oldestKey == null) break;
      _totalBytes -= _index[oldestKey]!.size;
      _index.remove(oldestKey);
      unawaited(File('${_dir.path}/$oldestKey.bin').delete());
    }
  }

  void _scheduleIndexWrite() {
    // The chain must never carry a failure forward: it would crash every
    // later await of _writeChain.
    _writeChain = _writeChain
        .then((_) => _writeIndex())
        .catchError((Object _) {});
  }

  Future<void> _writeIndex() async {
    final entries = <String, dynamic>{};
    for (final e in _index.entries) {
      entries[e.key] = e.value.toJson();
    }
    final tmp = File('${_indexFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({'version': 1, 'entries': entries}),
        flush: true);
    await tmp.rename(_indexFile.path);
  }

  /// Waits until all queued persistence work has settled (shutdown, tests).
  Future<void> flush() async {
    await _ensureLoaded();
    await _writeChain;
  }

  /// Drops everything.
  Future<void> clear() async {
    await _ensureLoaded();
    _index.clear();
    _totalBytes = 0;
    _writeChain = _writeChain.then((_) async {
      if (!await _dir.exists()) return;
      await for (final f in _dir.list()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }).catchError((Object _) {});
    await _writeChain;
  }

  /// Diagnostics.
  @visibleForTesting
  int get totalBytes => _totalBytes;

  @visibleForTesting
  int get entryCount => _index.length;
}
