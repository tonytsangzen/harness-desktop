/// Unit tests for the E2E record codec, including a golden vector generated
/// by the bridge's Node implementation — the two sides MUST stay
/// byte-compatible (same HKDF, AES-256-GCM, nonce layout, AAD).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/core/e2e_codec.dart';

const goldenSecret = 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE';
const goldenHostId = '1234567890123';

void main() {
  test('HKDF key derivation matches the bridge implementation', () {
    final key = e2eKey(goldenSecret, goldenHostId);
    // Computed with node: hkdfSync('sha256', ikm=0x41*32, salt=hostId,
    // info='dsh-e2e-v1', 32).
    expect(
      bytesToHex(key),
      '9C08CDAD44DEBB680945BD3B9C1B8D84CBDFA2488FAA99926E987E464FBF70EF',
    );
  });

  test('seals byte-for-byte like the bridge (golden record)', () async {
    final codec = E2eCodec(secret: goldenSecret, hostId: goldenHostId);
    final record = await codec.seal(
      dirBridgeToDevice,
      utf8.encode('hello-e2e'),
    );
    // Generated with node: flags=FLAG_BATCH, dir=1, counter=0, no deflate.
    expect(
      bytesToHex(record),
      '4532453102000000010000000000000000'
      'F61F85ABC4C425C6FC57C65AA5A91B5ADACD82B7F85D1F89B0',
    );
  });

  test('opens the bridge golden record', () async {
    final codec = E2eCodec(secret: goldenSecret, hostId: goldenHostId);
    final record = await codec.open(
      dirBridgeToDevice,
      _hex(
        '4532453102000000010000000000000000'
        'F61F85ABC4C425C6FC57C65AA5A91B5ADACD82B7F85D1F89B0',
      ),
    );
    expect(record, isNotNull);
    expect(record!.flags & flagBatch, flagBatch);
    expect(utf8.decode(record.body), 'hello-e2e');
  });

  test('round-trips large payloads through deflate', () async {
    final codec = E2eCodec(secret: goldenSecret, hostId: goldenHostId);
    final plain = utf8.encode('dsh-index ' * 200); // compressible
    final sealed = await codec.seal(dirDeviceToBridge, plain);
    final opened = await codec.open(dirDeviceToBridge, sealed);
    expect(opened, isNotNull);
    expect(opened!.flags & flagDeflate, flagDeflate,
        reason: 'compressible payloads must be deflated');
    expect(utf8.decode(opened.body), utf8.decode(plain));
  });

  test('rejects tampered records and foreign keys', () async {
    final codec = E2eCodec(secret: goldenSecret, hostId: goldenHostId);
    final sealed = await codec.seal(dirDeviceToBridge, utf8.encode('secret'));
    final tampered = Uint8List.fromList(sealed);
    tampered[tampered.length - 3] ^= 0xFF; // flip a ciphertext bit
    expect(() => codec.open(dirDeviceToBridge, tampered),
        throwsA(isA<E2eBrokenException>()));

    final other = E2eCodec(
      secret: 'QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE',
      hostId: '9999999999999',
    );
    expect(() => other.open(dirDeviceToBridge, sealed),
        throwsA(isA<E2eBrokenException>()));
  });

  test('returns null for legacy plaintext payloads', () async {
    final codec = E2eCodec(secret: goldenSecret, hostId: goldenHostId);
    final opened = await codec.open(
      dirDeviceToBridge,
      utf8.encode('GET / HTTP/1.1\r\nHost: x\r\n\r\n'),
    );
    expect(opened, isNull);
  });
}

String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

Uint8List _hex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
