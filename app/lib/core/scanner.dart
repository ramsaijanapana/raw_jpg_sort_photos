import 'dart:io';
import 'package:path/path.dart' as p;
import 'constants.dart';
import 'models.dart';

/// Scans [folder] for RAW files.
///
/// Includes files in [folder] itself and in [folder/RAW/] if that subdirectory
/// exists. Results are sorted by file name (base name, not full path).
Future<List<File>> scanRaws(Directory folder) async {
  final results = <File>[];

  // Scan root folder
  if (await folder.exists()) {
    await for (final entity in folder.list(recursive: false)) {
      if (entity is File && isRaw(entity.path)) {
        results.add(entity);
      }
    }
  }

  // Also scan folder/RAW/ subdirectory if it exists
  final rawSub = Directory(p.join(folder.path, 'RAW'));
  if (await rawSub.exists()) {
    await for (final entity in rawSub.list(recursive: false)) {
      if (entity is File && isRaw(entity.path)) {
        results.add(entity);
      }
    }
  }

  // Sort by base file name (case-sensitive, matches Python behavior)
  results.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  return results;
}

/// Scans [folder] and pairs each RAW file with a companion JPG (if found).
///
/// For each RAW, looks for a file with the same stem and a JPG extension in:
/// 1. [folder] itself
/// 2. [folder/JPG/] subdirectory
///
/// Extensions tried (case-sensitive): .jpg, .JPG, .jpeg, .JPEG
Future<List<PhotoPair>> scanPairs(Directory folder) async {
  final raws = await scanRaws(folder);
  final jpgSub = Directory(p.join(folder.path, 'JPG'));

  final pairs = <PhotoPair>[];
  for (final rawFile in raws) {
    final stem = p.basenameWithoutExtension(rawFile.path);
    File? foundJpg;

    outer:
    for (final ext in const ['.jpg', '.JPG', '.jpeg', '.JPEG']) {
      for (final dir in [folder, jpgSub]) {
        final candidate = File(p.join(dir.path, '$stem$ext'));
        if (await candidate.exists()) {
          foundJpg = candidate;
          break outer;
        }
      }
    }

    pairs.add(PhotoPair(stem: stem, raw: rawFile, jpg: foundJpg));
  }

  return pairs;
}
