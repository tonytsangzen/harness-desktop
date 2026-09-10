/// Unit tests for pairing QR/link parsing.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_mobile/core/pairing_link.dart';

void main() {
  test('parses the native relay:// QR with scheme + pin', () {
    final data = parsePairingContent(
      'relay://relay.deepvisus.top/pair?device=1234567890123'
      '&scheme=https&dshPort=3099&lan=192.168.5.13:13080'
      '&e2e=abc-_123&pin=864209',
    );
    expect(data, isNotNull);
    expect(data!.relayBase, 'https://relay.deepvisus.top');
    expect(data.deviceId, '1234567890123');
    expect(data.dshPort, 3099);
    expect(data.lan, '192.168.5.13:13080');
    expect(data.e2eSecret, 'abc-_123');
    expect(data.pin, '864209');
  });

  test('parses URL-style pairing links (zcode scan-to-add)', () {
    final data = parsePairingContent(
      'https://relay.deepvisus.top/pair?device=1234567890123'
      '&dshPort=3080&pin=123456&e2e=xyz',
    );
    expect(data, isNotNull);
    expect(data!.relayBase, 'https://relay.deepvisus.top');
    expect(data.deviceId, '1234567890123');
    expect(data.pin, '123456');
    expect(data.e2eSecret, 'xyz');
    expect(data.lan, isNull);
    expect(data.dshPort, 3080);
  });

  test('http link keeps its own scheme', () {
    final data = parsePairingContent(
      'http://192.168.5.13:18445/pair?device=1234567890123',
    );
    expect(data!.relayBase, 'http://192.168.5.13:18445');
  });

  test('relay QR without scheme falls back to loopback detection', () {
    expect(
      parsePairingContent('relay://127.0.0.1:18445/pair?device=1')!.relayBase,
      'http://127.0.0.1:18445',
    );
    expect(
      parsePairingContent('relay://relay.example.com/pair?device=1')!
          .relayBase,
      'https://relay.example.com',
    );
  });

  test('any http(s) link is accepted; device is optional there', () {
    // zcode-style QRs may be plain links: the origin becomes the relay base
    // and the user completes the device ID manually.
    final data = parsePairingContent('https://example.com/some/path');
    expect(data, isNotNull);
    expect(data!.relayBase, 'https://example.com');
    expect(data.deviceId, isNull);
  });

  test('rejects non-pairing content', () {
    expect(parsePairingContent('just some text'), isNull);
    expect(parsePairingContent('relay://host/pair'), isNull,
        reason: 'native QRs must carry device=');
  });

  test('invalid PIN is dropped but does not reject the QR', () {
    final data = parsePairingContent(
      'https://relay.example.com/pair?device=1&pin=abc',
    );
    expect(data, isNotNull);
    expect(data!.pin, isNull);
  });
}
