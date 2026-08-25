import 'package:path/path.dart' as p;

import 'constants.dart';
import 'folder_ref.dart';
import 'models.dart';
import 'storage/storage_gateway.dart';

/// Scans [folder] for RAW files.
///
/// Includes files in [folder] itself and in [folder/RAW/] if that subdirectory
/// exists. Results are sorted by file name (base name, not full path).
Future<List<StorageEntry>> scanRaws(
  FolderRef folder, {
  required StorageGateway gateway,
}) async {
  final results = <StorageEntry>[];

  if (await gateway.exists(folder)) {
    final children = await gateway.listChildren(folder);
    for (final entry in children) {
      if (!entry.isDirectory && isRaw(entry.name)) {
        results.add(entry);
      }
    }
  }

  final rawSub = await gateway.childByName(folder, 'RAW');
  if (rawSub != null && rawSub.isDirectory) {
    final rawChildren = await gateway.listChildren(
      folder,
      childDocumentId: 'RAW',
    );
    for (final entry in rawChildren) {
      if (!entry.isDirectory && isRaw(entry.name)) {
        results.add(entry);
      }
    }
  }

  results.sort((a, b) => a.name.compareTo(b.name));
  return results;
}

/// Scans [folder] and pairs each RAW file with a companion JPG (if found).
///
/// For each RAW, looks for a file with the same stem and a JPG extension in:
/// 1. [folder] itself
/// 2. [folder/JPG/] subdirectory
///
/// Extensions tried (case-sensitive): .jpg, .JPG, .jpeg, .JPEG
Future<List<PhotoPair>> scanPairs(
  FolderRef folder, {
  required StorageGateway gateway,
}) async {
  final raws = await scanRaws(folder, gateway: gateway);
  final pairs = <PhotoPair>[];

  for (final rawFile in raws) {
    final stem = p.basenameWithoutExtension(rawFile.name);
    StorageEntry? foundJpg;

    outer:
    for (final ext in const ['.jpg', '.JPG', '.jpeg', '.JPEG']) {
      final name = '$stem$ext';
      for (final parentId in const [null, 'JPG']) {
        final candidate = await gateway.childByName(
          folder,
          name,
          parentDocumentId: parentId,
        );
        if (candidate != null && !candidate.isDirectory) {
          foundJpg = candidate;
          break outer;
        }
      }
    }

    pairs.add(PhotoPair(stem: stem, raw: rawFile, jpg: foundJpg));
  }

  return pairs;
}
