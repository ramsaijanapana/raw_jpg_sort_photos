import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'constants.dart';
import 'models.dart';

/// Sorts RAW and JPG files from [input] into [output]/RAW/ and [output]/JPG/.
///
/// When [input] and [output] resolve to the same directory, files are MOVED;
/// otherwise they are COPIED (originals are preserved).
///
/// Files that already exist at the destination are skipped (not overwritten).
/// Non-RAW, non-JPG files are left untouched.
///
/// Returns a [SortResult] describing what happened. If no RAW or JPG files
/// are found, returns a result with rawCount=0, jpgCount=0, skipped=0.
Future<SortResult> sortPhotos({
  required Directory input,
  required Directory output,
  void Function(SortProgress)? onProgress,
}) async {
  // Create the output directory first so it exists for the comparison and any
  // subsequent file operations.
  await output.create(recursive: true);

  // Resolve both paths to detect same-dir (in-place) operation. Resolution can
  // throw when a path does not exist; fall back per-path to a normalized
  // absolute path so the comparison still works.
  final inputResolved = _resolveDir(input);
  final outputResolved = _resolveDir(output);
  final sameDir = inputResolved == outputResolved;

  // Collect files (non-recursive, flat listing of input directory)
  final files = <File>[];
  await for (final entity in input.list(recursive: false)) {
    if (entity is File) {
      final ext = p.extension(entity.path).toLowerCase();
      if (rawExtensions.contains(ext) || jpgExtensions.contains(ext)) {
        files.add(entity);
      }
    }
  }

  final total = files.length;

  if (total == 0) {
    return SortResult(
      rawCount: 0,
      jpgCount: 0,
      skipped: 0,
      moved: sameDir,
      outputPath: output.path,
    );
  }

  int rawCount = 0;
  int jpgCount = 0;
  int skipped = 0;
  int processed = 0;

  for (final file in files) {
    final ext = p.extension(file.path).toLowerCase();
    final isRawFile = rawExtensions.contains(ext);
    final destDir = Directory(p.join(output.path, isRawFile ? 'RAW' : 'JPG'));

    // Create destination directory if needed
    await destDir.create(recursive: true);

    final dest = File(p.join(destDir.path, p.basename(file.path)));
    processed++;

    onProgress?.call(SortProgress(
      current: processed,
      total: total,
      fileName: p.basename(file.path),
    ));

    // Skip if destination already exists (no overwrite)
    if (await dest.exists()) {
      skipped++;
      continue;
    }

    if (sameDir) {
      // MOVE: try rename first, fall back to copy+delete on cross-volume
      await _moveFile(file, dest);
    } else {
      // COPY: preserve original
      await file.copy(dest.path);
    }

    if (isRawFile) {
      rawCount++;
    } else {
      jpgCount++;
    }
  }

  return SortResult(
    rawCount: rawCount,
    jpgCount: jpgCount,
    skipped: skipped,
    moved: sameDir,
    outputPath: output.path,
  );
}

/// Resolves [dir] to a canonical path for same-dir comparison, falling back to
/// a normalized absolute path when resolution fails (e.g. path not found).
String _resolveDir(Directory dir) {
  try {
    return dir.resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(dir.absolute.path);
  }
}

/// Moves [src] to [dest] using rename; falls back to copy+delete on failure
/// (e.g., cross-volume move where rename is not supported).
Future<void> _moveFile(File src, File dest) async {
  try {
    await src.rename(dest.path);
  } on FileSystemException {
    // Cross-volume fallback: copy then delete
    await src.copy(dest.path);
    await src.delete();
  }
}
