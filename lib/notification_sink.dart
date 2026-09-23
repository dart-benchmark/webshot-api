import 'dart:io';

import 'metadata.dart' show isPrivateOrLoopbackHost, hexFingerprint;

/// Strategy interface for the "notify me when a screenshot is ready"
/// feature -- callers pick a delivery mechanism per request instead of this
/// API hard-coding one.
abstract class NotificationSink {
  Future<void> send(String message);
}

/// Delivers the notification to an arbitrary caller-provided webhook target.
/// Used when a caller hasn't been onboarded onto this API's own audit log
/// and instead wants completion pings routed to their own listener.
class WebhookNotificationSink implements NotificationSink {
  final String targetUrl;
  WebhookNotificationSink(this.targetUrl);

  @override
  Future<void> send(String message) async {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.parse(targetUrl)); // SINK: PLANTED-Dart-HR-69
      request.headers.contentType = ContentType.text;
      request.write(message);
      await request.close();
    } finally {
      client.close(force: true);
    }
  }
}

/// Same delivery mechanism, but only ever dials a webhook target whose host
/// isn't a private/loopback/link-local address -- introduced once the
/// webhook option started accepting a caller-supplied host directly instead
/// of a value chosen from the caller's own pre-registered integrations.
class ValidatedWebhookNotificationSink implements NotificationSink {
  final String targetUrl;
  ValidatedWebhookNotificationSink(this.targetUrl);

  @override
  Future<void> send(String message) async {
    final uri = Uri.parse(targetUrl);
    if (isPrivateOrLoopbackHost(uri.host)) {
      throw ArgumentError('refusing to notify an internal host');
    }
    final client = HttpClient();
    try {
      final request =
          await client.postUrl(uri); // SAFE_SINK: PLANTED-Dart-HR-69-safe
      request.headers.contentType = ContentType.text;
      request.write(message);
      await request.close();
    } finally {
      client.close(force: true);
    }
  }
}

/// Same webhook delivery as [WebhookNotificationSink], but skips TLS
/// certificate validation for the outbound connection -- introduced for
/// on-prem installs whose webhook receiver terminates TLS with a
/// certificate this process's default trust store doesn't recognize
/// (typically a self-signed cert on a customer's own collector).
class InsecureTlsWebhookNotificationSink implements NotificationSink {
  final String targetUrl;
  InsecureTlsWebhookNotificationSink(this.targetUrl);

  @override
  Future<void> send(String message) async {
    final client = HttpClient();
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) =>
            true; // SINK: PLANTED-Dart-HR-278
    try {
      final request = await client.postUrl(Uri.parse(targetUrl));
      request.headers.contentType = ContentType.text;
      request.write(message);
      await request.close();
    } finally {
      client.close(force: true);
    }
  }
}

/// Same webhook delivery, but only ever accepts a certificate whose SHA-1
/// fingerprint is on this process's own hard-coded allow-list --
/// certificate pinning for on-prem installs that would rather pin the
/// collector's known certificate than disable validation outright.
class PinnedTlsWebhookNotificationSink implements NotificationSink {
  final String targetUrl;
  PinnedTlsWebhookNotificationSink(this.targetUrl);

  /// SHA-1 fingerprints (hex, lowercase) of the certificates this sink
  /// trusts for a pinned on-prem webhook receiver.
  static const Set<String> _pinnedFingerprints = {
    'de1e42fa5c8b1a4b5e9d3f0c2a7b6d8e1f0a9c3b',
  };

  @override
  Future<void> send(String message) async {
    final client = HttpClient();
    client.badCertificateCallback = (X509Certificate cert, String host,
            int port) =>
        _pinnedFingerprints.contains(
            hexFingerprint(cert.sha1)); // SAFE_SINK: PLANTED-Dart-HR-278-safe
    try {
      final request = await client.postUrl(Uri.parse(targetUrl));
      request.headers.contentType = ContentType.text;
      request.write(message);
      await request.close();
    } finally {
      client.close(force: true);
    }
  }
}

/// Writes the notification to the server's own log instead of making any
/// network call -- the default sink when a caller hasn't opted into webhook
/// delivery at all.
class LogNotificationSink implements NotificationSink {
  const LogNotificationSink();

  @override
  Future<void> send(String message) async {
    print('[notify] $message');
  }
}
