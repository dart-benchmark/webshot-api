import 'dart:convert';
import 'dart:io';

/// Lightweight page-metadata lookup used by the `/meta` endpoint so a caller
/// can preview a page's title and favicon without waiting for a full
/// puppeteer screenshot render. Fetches the raw HTML directly over HTTP.
Future<Map<String, String?>> fetchPageMetadata(String targetUrl) async {
  final client = HttpClient();
  try {
    final request =
        await client.getUrl(Uri.parse(targetUrl)); // SINK: PLANTED-Dart-HR-67
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return {
      'title': _extractTag(body, 'title'),
      'favicon': _extractFavicon(body),
    };
  } finally {
    client.close(force: true);
  }
}

/// Same feature, but only fetches the target after confirming it does not
/// resolve to a private, loopback, or link-local address -- the mitigation
/// added once `/meta?trusted=true` was introduced to close off internal-
/// network probing via this endpoint.
Future<Map<String, String?>> fetchTrustedPageMetadata(String targetUrl) async {
  final uri = Uri.parse(targetUrl);
  if (isPrivateOrLoopbackHost(uri.host)) {
    throw ArgumentError('refusing to fetch metadata for an internal host');
  }
  final client = HttpClient();
  try {
    final request =
        await client.getUrl(uri); // SAFE_SINK: PLANTED-Dart-HR-67-safe
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return {
      'title': _extractTag(body, 'title'),
      'favicon': _extractFavicon(body),
    };
  } finally {
    client.close(force: true);
  }
}

/// Accepts any certificate presented for any host -- used by
/// [fetchPageMetadataAllowingInsecureTls] below so a metadata preview can
/// still be generated for a target whose HTTPS certificate isn't signed by
/// a CA this process's default trust store recognizes (a common shape for
/// internal dashboards and staging deployments a caller wants a preview
/// of).
bool _acceptAnyCertificate(X509Certificate cert, String host, int port) => true;

/// Same metadata lookup as [fetchPageMetadata], but skips TLS certificate
/// validation entirely for the outbound connection -- opted into via
/// `/meta?tlsMode=insecure` for targets whose certificate this process's
/// default trust store won't validate (self-signed, internal CA, expired
/// staging cert, ...).
Future<Map<String, String?>> fetchPageMetadataAllowingInsecureTls(
    String targetUrl) async {
  final client = HttpClient();
  client.badCertificateCallback =
      _acceptAnyCertificate; // SINK: PLANTED-Dart-HR-276
  try {
    final request = await client.getUrl(Uri.parse(targetUrl));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return {
      'title': _extractTag(body, 'title'),
      'favicon': _extractFavicon(body),
    };
  } finally {
    client.close(force: true);
  }
}

/// Same metadata lookup, but leaves certificate validation at its default
/// -- opted into via `/meta?tlsMode=strict`. An invalid, self-signed, or
/// hostname-mismatched certificate causes this to throw a
/// [HandshakeException] rather than silently completing the request.
Future<Map<String, String?>> fetchPageMetadataStrictTls(
    String targetUrl) async {
  final client = HttpClient(); // SAFE_SINK: PLANTED-Dart-HR-276-safe
  try {
    final request = await client.getUrl(Uri.parse(targetUrl));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    return {
      'title': _extractTag(body, 'title'),
      'favicon': _extractFavicon(body),
    };
  } finally {
    client.close(force: true);
  }
}

/// Hex-encodes a certificate fingerprint (e.g. [X509Certificate.sha1]) for
/// comparison against a hard-coded pinned allow-list. Shared by every
/// planted certificate-pinning safe twin in this project.
String hexFingerprint(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Rejects loopback/RFC1918-private/link-local (incl. the cloud
/// metadata-service range `169.254.0.0/16`) IPv4 hosts, plus bare
/// `localhost`. Shared by every planted safe twin in this project.
bool isPrivateOrLoopbackHost(String host) {
  final addr = InternetAddress.tryParse(host);
  if (addr == null) {
    return host == 'localhost';
  }
  if (addr.isLoopback) return true;
  if (addr.type == InternetAddressType.IPv4) {
    final parts = addr.address.split('.').map(int.parse).toList();
    if (parts[0] == 10) return true;
    if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;
    if (parts[0] == 192 && parts[1] == 168) return true;
    if (parts[0] == 169 && parts[1] == 254) return true;
  }
  return false;
}

String? _extractTag(String html, String tag) {
  final match =
      RegExp('<$tag[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true)
          .firstMatch(html);
  return match?.group(1)?.trim();
}

String? _extractFavicon(String html) {
  final match = RegExp(
          r'''<link[^>]+rel=["'](?:shortcut icon|icon)["'][^>]*href=["']([^"']+)["']''',
          caseSensitive: false)
      .firstMatch(html);
  return match?.group(1);
}

/// The metadata field keys this service knows how to extract from a page, as a
/// newline-joined manifest. Callers can probe which fields match a naming
/// convention via `/meta-fields?pattern=...` before requesting a full metadata
/// lookup with `/meta`.
const String _extractableFieldManifest =
    'title\nfavicon\ndescription\nog:title\nog:image\nog:description\ncanonical\nauthor';

/// Returns the extractable metadata field keys whose name matches the
/// caller-supplied [namePattern]. Used by `/meta-fields` so a caller can
/// discover which of this service's metadata fields follow a naming pattern.
List<String> matchExtractableFields(String namePattern) {
  final selector = _buildFieldSelector(namePattern);
  final fields = _extractableFieldManifest.split('\n');
  final matched = <String>[];
  for (final field in fields) {
    //CWE-1333
    //SINK
    if (selector.hasMatch(field)) {
      matched.add(field);
    }
  }
  return matched;
}

/// Compiles [namePattern] into a case-insensitive matcher for field-name
/// lookups. Case is folded so a caller doesn't have to know the manifest's
/// exact capitalization.
RegExp _buildFieldSelector(String namePattern) {
  return RegExp(namePattern, caseSensitive: false);
}
