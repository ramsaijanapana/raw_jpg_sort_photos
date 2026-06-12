import 'dart:io';
import 'package:path/path.dart' as p;
import 'cull_session.dart';
import 'models.dart';

/// Exports kept photos to [destination].
///
/// For every [PhotoPair] whose stem is flagged [CullFlag.keep] in [session]:
/// - Always copies [pair.raw] to [destination]
/// - When [includeJpgs] is true and [pair.jpg] is non-null, copies the JPG too
///
/// Overwrites existing files at the destination (matches Python shutil.copy2
/// behavior). Returns an [ExportResult] with the count of files copied.
Future<ExportResult> exportKept({
  required Directory source,
  required Directory destination,
  required List<PhotoPair> pairs,
  required CullSession session,
  required bool includeJpgs,
}) async {
  await destination.create(recursive: true);

  int copied = 0;

  for (final pair in pairs) {
    if (session.flagFor(pair.stem) != CullFlag.keep) continue;

    // Copy RAW file
    final rawDest = File(p.join(destination.path, p.basename(pair.raw.path)));
    await pair.raw.copy(rawDest.path);
    copied++;

    // Copy JPG if requested and available
    if (includeJpgs && pair.jpg != null) {
      final jpgDest = File(p.join(destination.path, p.basename(pair.jpg!.path)));
      await pair.jpg!.copy(jpgDest.path);
      copied++;
    }
  }

  return ExportResult(
    copied: copied,
    outputPath: destination.path,
  );
}
