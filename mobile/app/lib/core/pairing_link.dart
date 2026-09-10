/// Parser for pairing QR contents.
///
/// Three shapes are accepted:
/// - the native `relay://<host>/pair?device=…&scheme=…` QR the desktop shells
///   render,
/// - URL-style pairing links carrying a `device=` query (the zcode
///   scan-to-add pattern), and
/// - any other `http(s)` link: its origin still becomes the relay base —
///   `device` is optional then and the user completes pairing manually.
///   Unknown/foreign content (text, app-specific schemes) is rejected.
library;

class PairingData {
  const PairingData({
    required this.relayBase,
    required this.deviceId,
    this.lan,
    this.e2eSecret,
    this.pin,
    this.dshPort = 3080,
  });

  /// Relay base URL, e.g. `https://relay.example.com`.
  final String relayBase;

  /// Device ID from the QR/link; null when the link did not carry one (the
  /// user then completes it manually).
  final String? deviceId;
  final String? lan;
  final String? e2eSecret;

  /// Six-digit pairing PIN, when the QR/link carries one.
  final String? pin;
  final int dshPort;
}

class DirectLink {
  const DirectLink({
    required this.raw,
    required this.origin,
    this.device,
    this.pin,
    this.e2eSecret,
    this.lan,
    this.dshPort = 3080,
  });

  /// The scanned link, saved verbatim.
  final String raw;

  /// `scheme://authority` of the link — used as the relay base when
  /// connecting (the direct-link channel).
  final String origin;
  final String? device;
  final String? pin;
  final String? e2eSecret;
  final String? lan;
  final int dshPort;
}

/// The zcode scan-to-save channel: **no validation**. Any scanned content
/// carrying a URI scheme is treated as a link; parameters are extracted
/// verbatim without format checks (PIN length, device shape, etc.). Only
/// unparseable text without a scheme is rejected.
DirectLink? parseDirectLink(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.scheme.isEmpty) return null;
  return DirectLink(
    raw: raw.trim(),
    origin: uri.hasAuthority ? '${uri.scheme}://${uri.authority}' : raw.trim(),
    device: uri.queryParameters['device'],
    pin: uri.queryParameters['pin'],
    e2eSecret: uri.queryParameters['e2e'],
    lan: uri.queryParameters['lan'],
    dshPort: int.tryParse(uri.queryParameters['dshPort'] ?? '') ?? 3080,
  );
}

/// Parses [raw] QR content; returns null when it is not a pairing QR/link.
PairingData? parsePairingContent(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return null;
  final isRelayQr = raw.startsWith('relay://');
  final isLink = uri.scheme == 'http' || uri.scheme == 'https';
  if (!isRelayQr && !isLink) return null;
  // relay:// QRs are shell-generated and always carry device=; plain links
  // are accepted even without one (device typed manually afterwards).
  final device = uri.queryParameters['device'];
  if (isRelayQr && (device == null || device.isEmpty)) return null;

  // Scheme precedence: explicit query param (native QRs), then the URL's own
  // scheme (link form), then loopback detection for scheme-less relay QRs.
  final schemeParam = uri.queryParameters['scheme'];
  String scheme;
  if (schemeParam == 'http' || schemeParam == 'https') {
    scheme = schemeParam!;
  } else if (isLink) {
    scheme = uri.scheme;
  } else {
    final host = uri.host;
    scheme = host == 'localhost' || host == '::1' || host.startsWith('127.')
        ? 'http'
        : 'https';
  }

  final pin = uri.queryParameters['pin'];
  return PairingData(
    relayBase: '$scheme://${uri.authority}',
    deviceId: (device == null || device.isEmpty) ? null : device,
    lan: uri.queryParameters['lan'],
    e2eSecret: uri.queryParameters['e2e'],
    pin: pin != null && RegExp(r'^\d{6}$').hasMatch(pin) ? pin : null,
    dshPort: int.tryParse(uri.queryParameters['dshPort'] ?? '') ?? 3080,
  );
}
