/// End-to-end record codec for the bridge ↔ app tunnel hop.
///
/// The relay routes frames but must never see dsh traffic, so stream payloads
/// are sealed between the two endpoints under a key derived (HKDF-SHA256)
/// from a secret the pairing QR carries to the phone out-of-band. Records
/// also deflate-compress their payload.
///
/// Record layout:
/// ```
/// 'E2E1' | flags | nonce(12) | AES-256-GCM ciphertext(+16B tag)
/// flags:  bit0 = payload is deflate-raw compressed, bit1 = peer aggregates
/// nonce:  direction(4 BE) || counter(8 BE), one counter per direction
/// AAD:    magic | flags
/// ```
/// Encryption is negotiated per stream: the bridge injects a HELLO record
/// (empty payload) as the first payload of every stream when it holds the
/// secret; a peer that fails to acknowledge keeps the stream plaintext, so
/// legacy peers keep working unchanged. The codec is connection-scoped:
/// records may be aggregated across streams, so counters are per direction,
/// not per stream.
library;

import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:cryptography/cryptography.dart';

const e2eMagic = [0x45, 0x32, 0x45, 0x31]; // "E2E1"
const int flagDeflate = 1;
const int flagBatch = 2;
const int dirBridgeToDevice = 1;
const int dirDeviceToBridge = 2;

/// HKDF-SHA256 (RFC 5869) over the QR-carried secret.
Uint8List e2eKey(String secretBase64Url, String hostId) {
  final ikm = base64Url.decode(base64Url.normalize(secretBase64Url));
  final salt = utf8.encode(hostId);
  final info = utf8.encode('dsh-e2e-v1');
  final prk = hash.Hmac(hash.sha256, salt).convert(ikm).bytes;
  final okm = <int>[];
  var t = <int>[];
  var counter = 1;
  while (okm.length < 32) {
    t = hash.Hmac(hash.sha256, prk).convert([...t, ...info, counter]).bytes;
    okm.addAll(t);
    counter++;
  }
  return Uint8List.fromList(okm.sublist(0, 32));
}

/// A decoded record. [body] is the raw stream payload (already decompressed);
/// empty for HELLO records.
class E2eRecord {
  const E2eRecord(this.flags, this.body);
  final int flags;
  final Uint8List body;
  bool get isHello => body.isEmpty;
}

class E2eBrokenException implements Exception {
  @override
  String toString() => 'E2eBrokenException: record failed to authenticate';
}

/// Connection-scoped codec half: seals/opens records with per-direction
/// counters. Methods are async (platform-backed AES-GCM); callers must keep
/// per-direction ordering (e.g. via a chained future) so counters stay monotonic.
class E2eCodec {
  E2eCodec({required String secret, required String hostId})
    : _key = e2eKey(secret, hostId);

  static final AesGcm _aes = AesGcm.with256bits();

  final List<int> _key;
  int _txSeq = 0;

  /// Seals one payload. Empty payload = HELLO. Returns the full record.
  Future<Uint8List> seal(int dir, List<int> plain) async {
    final nonce = Uint8List(12);
    final bd = ByteData.view(nonce.buffer);
    bd.setUint32(0, dir);
    bd.setUint64(4, _txSeq);
    _txSeq++;
    var flags = flagBatch;
    var body = plain;
    if (plain.length >= 64) {
      final deflated = ZLibCodec(raw: true).encoder.convert(plain);
      if (deflated.length < plain.length) {
        flags |= flagDeflate;
        body = deflated;
      }
    }
    final box = await _aes.encrypt(
      body,
      secretKey: SecretKey(_key),
      nonce: nonce,
      aad: [...e2eMagic, flags],
    );
    final out = BytesBuilder()
      ..add(e2eMagic)
      ..addByte(flags)
      ..add(nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.toBytes();
  }

  /// Opens one record. Returns null when the bytes are not a record at all
  /// (legacy plaintext traffic). Throws [E2eBrokenException] when sealed but
  /// not authenticating (wrong key / tampered).
  Future<E2eRecord?> open(int dir, List<int> record) async {
    if (record.length < 4 + 1 + 12 + 16 ||
        record[0] != e2eMagic[0] ||
        record[1] != e2eMagic[1] ||
        record[2] != e2eMagic[2] ||
        record[3] != e2eMagic[3]) {
      return null;
    }
    final flags = record[4];
    final nonce = Uint8List.fromList(record.sublist(5, 17));
    final tagged = record.sublist(17);
    final tag = Uint8List.fromList(tagged.sublist(tagged.length - 16));
    try {
      final clear = await _aes.decrypt(
        SecretBox(
          Uint8List.fromList(tagged.sublist(0, tagged.length - 16)),
          nonce: nonce,
          mac: Mac(tag),
        ),
        secretKey: SecretKey(_key),
        aad: [...e2eMagic, flags],
      );
      var body = clear;
      if (flags & flagDeflate != 0) {
        body = ZLibCodec(raw: true).decoder.convert(clear);
      }
      return E2eRecord(flags, Uint8List.fromList(body));
    } on SecretBoxAuthenticationError {
      throw E2eBrokenException();
    }
  }

  /// The exact bytes of a HELLO record (empty payload, batch flag).
  Future<Uint8List> hello(int dir) => seal(dir, const []);
}
