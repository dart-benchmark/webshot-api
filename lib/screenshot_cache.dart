import 'dart:io';
import 'dart:typed_data';

/// Screenshot/report *staging* support -- lets a caller-facing route
/// persist a just-rendered screenshot or PDF to a scratch file on disk
/// instead of only ever holding it in memory, either to serve a repeated
/// identical request without re-rendering (see `/cached-shot` in api.dart)
/// or to hand a large export off to a slower downstream step (an export
/// worker, a validation pass) without keeping the whole payload resident
/// the entire time. `webshot-api` had no existing temp-file usage anywhere
/// before this -- every function below builds directly on `dart:io`'s
/// `File`/`Directory`, already imported throughout this project, so no new
/// pubspec dependency was needed.
///
/// PLANTED (CWE-377, Insecure Temporary File): several of the staging
/// helpers below build their on-disk path from caller-influenceable or
/// otherwise-predictable input and write into the shared, world-writable
/// `Directory.systemTemp` with the platform's default (non-restricted)
/// creation mode, or use a separate check-then-create step instead of an
/// atomic exclusive create. Each has a hardened sibling using
/// `Directory.systemTemp.createTempSync()` (or `File.createSync(exclusive:
/// true)` where the name genuinely needs to stay fixed) -- see
/// `benchmarking/dart/planting-research/dart-cwe-377-planting-research.md`.

/// Describes one caller's request to stage (or reuse) a rendered report
/// under a caller-chosen key -- built in api.dart's `/report-shot` route,
/// resolved here, mirroring how `export_service.dart`'s `ExportRequest` is
/// already built in api.dart and resolved in a different file.
class ReportStagingRequest {
  final String reportKey;
  final Uint8List bytes;
  ReportStagingRequest(this.reportKey, this.bytes);
}

/// Stages an exported PDF's bytes to a scratch file for a downstream export
/// worker to pick up later, keyed by the caller-supplied job id and a
/// coarse timestamp -- an indirect route to the actual sink, reached via
/// `/export-pdf` rather than inline in the route handler itself.
String stagePdfExport(String jobId, Uint8List bytes) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  var stagingName = 'webshot_export_';
  stagingName += jobId;
  stagingName += '_';
  stagingName += timestamp.toString();
  stagingName += '.pdf';
  final stagingPath = '${Directory.systemTemp.path}/$stagingName';
  final file = File(stagingPath);
  file.createSync(); // SINK: PLANTED-Dart-HR-141
  file.writeAsBytesSync(bytes);
  return stagingPath;
}

/// Same feature, but stages the export into a `createTempSync`-produced
/// scratch directory instead of a name built from caller/timestamp input.
String stagePdfExportSafely(String jobId, Uint8List bytes) {
  final stagingDir = Directory.systemTemp
      .createTempSync('webshot_export_'); // SAFE_SINK: PLANTED-Dart-HR-141-safe
  final file = File('${stagingDir.path}/export.pdf');
  file.writeAsBytesSync(bytes);
  return file.path;
}

/// Resolves (or creates) the staged file for [request.reportKey], across
/// files from where the request was built in api.dart -- checks whether a
/// staged copy already exists and, if not, creates and writes it as two
/// separate steps: a real check-then-create window in which a concurrent
/// request for the same reportKey (or another local process) can win the
/// race, ending up with this call silently reading back whatever content
/// won.
Uint8List resolveOrCreateStagedReport(ReportStagingRequest request) {
  final stagedFile = File(
      '${Directory.systemTemp.path}/webshot_report_${request.reportKey}.dat');
  if (!stagedFile.existsSync()) {
    stagedFile.createSync(); // SINK: PLANTED-Dart-HR-142
    stagedFile.writeAsBytesSync(request.bytes);
  }
  return stagedFile.readAsBytesSync();
}

/// Same feature, but closes the check-then-create race by asking the
/// filesystem to create the staged file atomically instead of checking
/// first -- and, critically, never falls back to silently trusting and
/// reading back whatever was already sitting at that guessable path if the
/// atomic create fails. A pre-existing entry there (another local actor's
/// planted file, or a symlink redirecting to something else entirely)
/// could be perfectly legitimate leftover state, or it could be exactly
/// the TOCTOU-driven substitution this CWE is about -- since the two
/// cannot be told apart from the filesystem alone, the only safe move is
/// to never read through it and instead stage this render under a fresh,
/// unguessable path.
Uint8List resolveOrCreateStagedReportSafely(ReportStagingRequest request) {
  final stagedFile = File(
      '${Directory.systemTemp.path}/webshot_report_${request.reportKey}.dat');
  try {
    stagedFile.createSync(exclusive: true); // SAFE_SINK: PLANTED-Dart-HR-142-safe
    stagedFile.writeAsBytesSync(request.bytes);
    return request.bytes;
  } on FileSystemException {
    final fallbackDir =
        Directory.systemTemp.createTempSync('webshot_report_fallback_');
    final fallbackFile = File('${fallbackDir.path}/report.dat');
    fallbackFile.writeAsBytesSync(request.bytes);
    return request.bytes;
  }
}

/// Strategy interface for how a report's temp file is actually created --
/// mirrors this project's existing per-concern strategy-interface
/// convention (`BrowserSource` in browser_source.dart, `NotificationSink`
/// in notification_sink.dart) but for report *staging* rather than browser
/// acquisition or completion notification.
abstract class ReportTempFileProvider {
  File create(String reportId, Uint8List bytes);
}

/// Builds the staged file's path directly from the caller-supplied report
/// id -- the original implementation, from before this feature needed to
/// support untrusted, request-supplied ids.
class LegacyReportTempFileProvider implements ReportTempFileProvider {
  @override
  File create(String reportId, Uint8List bytes) {
    final file =
        File('${Directory.systemTemp.path}/webshot_report_$reportId.tmp');
    file.createSync(); // SINK: PLANTED-Dart-HR-143
    file.writeAsBytesSync(bytes);
    return file;
  }
}

/// Same feature, but always asks `createTempSync` for a randomized,
/// restrictively-created scratch file instead of deriving the name from
/// the caller-supplied report id -- added once this provider started being
/// reachable with an id read straight off the request.
class AtomicReportTempFileProvider implements ReportTempFileProvider {
  @override
  File create(String reportId, Uint8List bytes) {
    final dir = Directory.systemTemp
        .createTempSync('webshot_report_'); // SAFE_SINK: PLANTED-Dart-HR-143-safe
    final file = File('${dir.path}/report.tmp');
    file.writeAsBytesSync(bytes);
    return file;
  }
}

int _stagingSequence = 0;

bool _startsWithMagic(Uint8List bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

/// Stages [bytes] to a scratch file, numbered sequentially in the order
/// staging requests arrive -- an enumerable, guessable path, since a
/// caller who fires several requests can infer the counter's current value
/// -- then validates the staged content actually starts with the magic
/// bytes [expectedFormat] claims. The cleanup call sits in the ordinary
/// success-path body, after the validation check, so a caller that lies
/// about `expectedFormat` makes this throw *before* `deleteSync()` runs,
/// leaving the staged file behind on disk. Used by
/// `/validated-report-shot`.
Map<String, Object?> renderAndValidateStagedReport(
    Uint8List bytes, String expectedFormat) {
  final sequence = _stagingSequence++;
  final file =
      File('${Directory.systemTemp.path}/webshot_validated_$sequence.tmp');
  file.createSync(); // SINK: PLANTED-Dart-HR-144
  file.writeAsBytesSync(bytes);

  final expectedMagic = expectedFormat == 'pdf'
      ? [0x25, 0x50, 0x44, 0x46] // %PDF
      : [0x89, 0x50, 0x4E, 0x47]; // \x89PNG
  if (!_startsWithMagic(bytes, expectedMagic)) {
    throw FormatException(
        'staged content does not match claimed format $expectedFormat');
  }

  file.deleteSync();
  return {'status': 'ok', 'sequence': sequence};
}

/// Same feature, but stages into a `createTempSync`-produced scratch
/// directory (closing the predictable-name issue too, not just the
/// cleanup gap) and guarantees the cleanup runs via `finally` regardless
/// of whether the format validation throws.
Map<String, Object?> renderAndValidateStagedReportSafely(
    Uint8List bytes, String expectedFormat) {
  final stagingDir = Directory.systemTemp
      .createTempSync('webshot_validated_'); // SAFE_SINK: PLANTED-Dart-HR-144-safe
  final file = File('${stagingDir.path}/staged.tmp');
  try {
    file.writeAsBytesSync(bytes);
    final expectedMagic = expectedFormat == 'pdf'
        ? [0x25, 0x50, 0x44, 0x46]
        : [0x89, 0x50, 0x4E, 0x47];
    if (!_startsWithMagic(bytes, expectedMagic)) {
      throw FormatException(
          'staged content does not match claimed format $expectedFormat');
    }
    return {'status': 'ok'};
  } finally {
    if (file.existsSync()) {
      file.deleteSync();
    }
    stagingDir.deleteSync();
  }
}
