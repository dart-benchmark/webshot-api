import 'dart:io';
import 'dart:typed_data';

import 'metadata.dart' show isPrivateOrLoopbackHost;

/// Delivers a rendered screenshot straight to a caller-chosen destination
/// (a storage bucket's presigned upload URL, an internal webhook, a CI
/// artifact collector, ...) instead of making the caller poll this API for
/// the response body -- useful for batch jobs driven by another service.
class ExportRequest {
  final Uint8List bytes;
  final String destination;
  ExportRequest(this.bytes, this.destination);
}

/// Encapsulates the "accept anything" TLS trust decision as an instance
/// method rather than a bare closure, so [ExportService.uploadInsecureTls]
/// below can hand the policy object's own method off as the
/// [HttpClient.badCertificateCallback] tear-off -- a different call shape
/// from the inline closures used elsewhere in this project.
class _AcceptAnyCertificatePolicy {
  bool accept(X509Certificate cert, String host, int port) => true;
}

class ExportService {
  Future<bool> upload(ExportRequest request) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(request.destination);
      final httpRequest = await client.postUrl(uri); // SINK: PLANTED-Dart-HR-68
      httpRequest.headers.set('content-type', 'application/octet-stream');
      httpRequest.add(request.bytes);
      final response = await httpRequest.close();
      await response.drain();
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close(force: true);
    }
  }

  /// Same feature, gated behind a destination check -- added once the export
  /// feature was opened up to third-party-configured destinations, so this
  /// service can't be used to push captured screenshot bytes to an
  /// internal-only endpoint.
  Future<bool> uploadToVerifiedDestination(ExportRequest request) async {
    final uri = Uri.parse(request.destination);
    if (isPrivateOrLoopbackHost(uri.host) || uri.scheme != 'https') {
      throw ArgumentError('export destination must be a public https endpoint');
    }
    final client = HttpClient();
    try {
      final httpRequest =
          await client.postUrl(uri); // SAFE_SINK: PLANTED-Dart-HR-68-safe
      httpRequest.headers.set('content-type', 'application/octet-stream');
      httpRequest.add(request.bytes);
      final response = await httpRequest.close();
      await response.drain();
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close(force: true);
    }
  }

  /// Same delivery mechanism as [upload], but skips TLS certificate
  /// validation for the outbound connection -- opted into via
  /// `/export?tlsMode=insecure` for an on-prem export destination (a
  /// customer's own storage collector) that terminates TLS with a
  /// certificate this process's default trust store doesn't recognize.
  Future<bool> uploadInsecureTls(ExportRequest request) async {
    final uri = Uri.parse(request.destination);
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    final policy = _AcceptAnyCertificatePolicy();
    client.badCertificateCallback = policy.accept; // SINK: PLANTED-Dart-HR-277
    try {
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers.set('content-type', 'application/octet-stream');
      httpRequest.add(request.bytes);
      final response = await httpRequest.close();
      await response.drain();
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close(force: true);
    }
  }

  /// Same delivery mechanism, but leaves certificate validation at its
  /// default -- opted into via `/export?tlsMode=strict`. An invalid,
  /// self-signed, or hostname-mismatched certificate causes this to throw
  /// a [HandshakeException] rather than silently completing the upload.
  Future<bool> uploadStrictTls(ExportRequest request) async {
    final uri = Uri.parse(request.destination);
    final client = HttpClient(); // SAFE_SINK: PLANTED-Dart-HR-277-safe
    try {
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers.set('content-type', 'application/octet-stream');
      httpRequest.add(request.bytes);
      final response = await httpRequest.close();
      await response.drain();
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close(force: true);
    }
  }

  /// Pushes a rendered screenshot to the internal asset registry, which sits
  /// behind HTTP Basic auth. Reached via `/register-shot` so captures taken by
  /// batch jobs land in the shared registry without a separate upload round
  /// trip back through the caller.
  Future<bool> uploadToRegistry(ExportRequest request) async {
    final uri = Uri.parse(request.destination);
    final client = HttpClient();
    //CWE-798
    //SOURCE
    const registryPassword = 'r3g!stryPushSvc2019';
    final credentials =
        HttpClientBasicCredentials('registry-push-svc', registryPassword);
    //SINK
    client.addCredentials(uri, 'asset-registry', credentials);
    try {
      final httpRequest = await client.postUrl(uri);
      httpRequest.headers.set('content-type', 'application/octet-stream');
      httpRequest.add(request.bytes);
      final response = await httpRequest.close();
      await response.drain();
      return response.statusCode >= 200 && response.statusCode < 300;
    } finally {
      client.close(force: true);
    }
  }
}
