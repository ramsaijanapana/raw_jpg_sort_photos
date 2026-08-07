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
  final indexes = await Future.wait([
    _indexCompanionJpgs(folder),
    _indexCompanionJpgs(jpgSub),
  ]);
  final rootJpgs = indexes[0];
  final subdirectoryJpgs = indexes[1];

  final pairs = <PhotoPair>[];
  for (final rawFile in raws) {
    final stem = p.basenameWithoutExtension(rawFile.path);
    final foundJpg = rootJpgs[stem] ?? subdirectoryJpgs[stem];

    pairs.add(PhotoPair(stem: stem, raw: rawFile, jpg: foundJpg));
  }

  return pairs;
}

Future<Map<String, File>> _indexCompanionJpgs(Directory directory) async {
  final jpgsByStem = <String, File>{};
  if (!await directory.exists()) return jpgsByStem;

  await for (final entity in directory.list(recursive: false)) {
    if (entity is! File) continue;

    final extension = p.extension(entity.path).toLowerCase();
    if (extension != '.jpg' && extension != '.jpeg') continue;

    final stem = p.basenameWithoutExtension(entity.path);
    final existing = jpgsByStem[stem];
    jpgsByStem[stem] = existing == null
        ? entity
        : selectPreferredCompanionJpg(existing, entity);
  }

  return jpgsByStem;
}

/// Selects the deterministic winner between two companion JPG candidates.
///
/// This core selection rule is independent of filesystem enumeration order:
/// the `.jpg` extension family wins over `.jpeg`, then exact basenames use
/// code-unit ordering.
File selectPreferredCompanionJpg(File first, File second) =>
    _compareJpgCandidates(first, second) <= 0 ? first : second;

int _jpgExtensionRank(String path) =>
    p.extension(path).toLowerCase() == '.jpg' ? 0 : 1;

int _compareJpgCandidates(File a, File b) {
  final extensionComparison =
      _jpgExtensionRank(a.path).compareTo(_jpgExtensionRank(b.path));
  return extensionComparison != 0
      ? extensionComparison
      : p.basename(a.path).compareTo(p.basename(b.path));
}
