import 'dart:io';

/// Decision flag for a photo during culling.
enum CullFlag { undecided, keep, skip }

/// A RAW file paired with an optional companion JPG.
class PhotoPair {
  final String stem;
  final File raw;
  final File? jpg;

  const PhotoPair({
    required this.stem,
    required this.raw,
    this.jpg,
  });

  @override
  String toString() => 'PhotoPair(stem: $stem, raw: ${raw.path}, jpg: ${jpg?.path})';
}

/// Progress update emitted during sorting.
class SortProgress {
  final int current;
  final int total;
  final String fileName;

  const SortProgress({
    required this.current,
    required this.total,
    required this.fileName,
  });

  @override
  String toString() => 'SortProgress($current/$total, $fileName)';
}

/// Result returned after sorting completes.
class SortResult {
  final int rawCount;
  final int jpgCount;
  final int skipped;
  final bool moved;
  final String outputPath;
  /// True when the sort was cancelled before all files were processed.
  final bool cancelled;

  const SortResult({
    required this.rawCount,
    required this.jpgCount,
    required this.skipped,
    required this.moved,
    required this.outputPath,
    this.cancelled = false,
  });

  @override
  String toString() =>
      'SortResult(raw: $rawCount, jpg: $jpgCount, skipped: $skipped, moved: $moved, output: $outputPath, cancelled: $cancelled)';
}

/// Result returned after exporting kept photos.
class ExportResult {
  final int copied;
  final String outputPath;

  const ExportResult({
    required this.copied,
    required this.outputPath,
  });

  @override
  String toString() => 'ExportResult(copied: $copied, output: $outputPath)';
}
