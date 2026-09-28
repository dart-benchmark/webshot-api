import 'dart:io';
import 'dart:typed_data';

/// A caller-selected post-capture optimization request: which optimizer
/// binary to run over the rendered bytes, plus the tuning flags to hand it.
/// Threaded from the `/optimized-shot` handler down through
/// [ImageOptimizationPipeline] so the endpoint code stays focused on request
/// parsing rather than on the optimizer toolchain.
class OptimizationJob {
  final String tool;
  final List<String> tuning;
  OptimizationJob(this.tool, this.tuning);
}

/// Runs an external image optimizer over freshly-rendered screenshot bytes
/// before they are returned to the caller. Kept in its own module -- like
/// [ExportService] and the metadata helpers -- so the optimizer toolchain can
/// evolve without touching the request-handling layer in `api.dart`.
///
/// The supported optimizers are ordinary command-line tools (pngquant,
/// jpegoptim, cwebp, ...); the caller names which one to run per request via
/// `/optimized-shot?optimizer=...`.
class ImageOptimizationPipeline {
  /// Optimizes [bytes] with the caller-named [tool], applying an optional
  /// quality [level]. Returns the optimized bytes, or the originals if the
  /// tool produced nothing.
  Future<Uint8List> optimize(
      Uint8List bytes, String tool, String? level) async {
    if (tool.trim().isEmpty) {
      throw ArgumentError('an optimizer must be named');
    }
    final job = OptimizationJob(tool, _tuningFlags(level));
    return _runJob(bytes, job);
  }

  /// Maps a caller-supplied quality [level] to the optimizer's CLI flags.
  List<String> _tuningFlags(String? level) {
    final flags = <String>[];
    if (level != null && level.isNotEmpty) {
      flags.add('--quality');
      flags.add(level);
    }
    return flags;
  }

  /// Stages [bytes] to a scratch file, hands the file to [job]'s optimizer,
  /// then reads back whatever the tool wrote in place.
  Future<Uint8List> _runJob(Uint8List bytes, OptimizationJob job) async {
    final scratch = await Directory.systemTemp.createTemp('webshot_opt_');
    final target = File('${scratch.path}/capture.img');
    await target.writeAsBytes(bytes);
    try {
      await _invokeTool(job.tool, job.tuning, target.path);
      final optimized = await target.readAsBytes();
      return optimized.isEmpty ? bytes : optimized;
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  /// Invokes the optimizer [tool] against the staged [inputPath] with the
  /// resolved [tuning] flags.
  Future<ProcessResult> _invokeTool(
      String tool, List<String> tuning, String inputPath) {
    final args = <String>[...tuning, inputPath];
    //CWE-78
    //SINK
    return Process.run(tool, args);
  }
}
