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
/// Matching is case-sensitive for stems and case-insensitive for extensions.
/// Root-folder candidates win over `JPG/` candidates. Within one directory,
/// `.jpg` candidates win over `.jpeg`, then names use code-unit ordering.
Future<List<PhotoPair>> scanPairs(Directory folder) async {
  final raws = await scanRaws(folder);
  final jpgSub = Directory(p.join(folder.path, 'JPG'));

  final pairs = <PhotoPair>[];
  for (final rawFile in raws) {
    final stem = p.basenameWithoutExtension(rawFile.path);
    final foundJpg = await _findCompanionJpg(stem, [folder, jpgSub]);

    pairs.add(PhotoPair(stem: stem, raw: rawFile, jpg: foundJpg));
  }

  return pairs;
}

Future<File?> _findCompanionJpg(
  String stem,
  List<Directory> directories,
) async {
  for (final directory in directories) {
    if (!await directory.exists()) continue;

    final candidates = <File>[];
    await for (final entity in directory.list(recursive: false)) {
      if (entity is! File) continue;

      final extension = p.extension(entity.path).toLowerCase();
      if ((extension == '.jpg' || extension == '.jpeg') &&
          p.basenameWithoutExtension(entity.path) == stem) {
        candidates.add(entity);
      }
    }

    candidates.sort((a, b) {
      final extensionComparison = _jpgExtensionRank(
        a.path,
      ).compareTo(_jpgExtensionRank(b.path));
      return extensionComparison != 0
          ? extensionComparison
          : p.basename(a.path).compareTo(p.basename(b.path));
    });
    if (candidates.isNotEmpty) return candidates.first;
  }

  return null;
}

int _jpgExtensionRank(String path) =>
    p.extension(path).toLowerCase() == '.jpg' ? 0 : 1;
