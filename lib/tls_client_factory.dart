import 'dart:io';

/// Builds the [HttpClient] used by the `/policy-meta` route. Chooses its
/// TLS trust policy from BOTH the target host and the caller-supplied
/// `allowInsecureTls` flag together: certificate validation is relaxed
/// only for hosts that look like they belong to the operator's own
/// internal/dev namespace (`*.local`, anything containing "internal", or
/// bare `localhost`) -- those are the hosts most likely to terminate TLS
/// with a self-signed or internal-CA certificate this process's default
/// trust store won't recognize.
class TlsClientFactory {
  static HttpClient build(String host, bool allowInsecureTls) {
    if (allowInsecureTls && _looksInternal(host)) {
      final client = HttpClient();
      client.badCertificateCallback =
          (X509Certificate cert, String h, int port) =>
              true; // SINK: PLANTED-Dart-HR-279
      return client;
    }
    return _buildStrict();
  }

  static HttpClient _buildStrict() {
    return HttpClient(); // SAFE_SINK: PLANTED-Dart-HR-279-safe
  }

  /// A purely textual heuristic -- NOT a security boundary -- for whether
  /// a host looks like it belongs to the operator's own internal
  /// namespace. Since the caller fully controls the target URL (and
  /// therefore its host) via `/policy-meta?url=`, this check does nothing
  /// to stop an attacker from simply naming a host that satisfies it
  /// (e.g. `https://internal.attacker.example`, or pointing DNS for a
  /// `.local`-suffixed name they control).
  static bool _looksInternal(String host) =>
      host == 'localhost' ||
      host.contains('internal') ||
      host.endsWith('.local');
}
