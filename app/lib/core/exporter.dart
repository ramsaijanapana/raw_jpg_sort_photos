import 'dart:io';

import '../services/local_path_classifier.dart';
import 'cull_session.dart';
import 'folder_ref.dart';
import 'models.dart';
import 'storage/storage_gateway.dart';

/// Exports kept photos to [destination].
///
/// For every [PhotoPair] whose stem is flagged [CullFlag.keep] in [session]:
/// - Always copies [pair.raw] to [destination]
/// - When [includeJpgs] is true and [pair.jpg] is non-null, copies the JPG too
///
/// Overwrites existing files at the destination (matches Python shutil.copy2
/// behavior). Returns an [ExportResult] with the count of files copied.
///
/// [source] is unused and kept for call-site stability.
Future<ExportResult> exportKept({
  required FolderRef source,
  required FolderRef destination,
  required StorageGateway gateway,
  required List<PhotoPair> pairs,
  required CullSession session,
  required bool includeJpgs,
}) async {
  await _ensureLocalRoot(destination, gateway);

  int copied = 0;

  for (final pair in pairs) {
    if (session.flagFor(pair.stem) != CullFlag.keep) continue;

    copied += await _copyIfPresent(gateway, pair.raw, destination);
    if (includeJpgs && pair.jpg != null) {
      copied += await _copyIfPresent(gateway, pair.jpg!, destination);
    }
  }

  return ExportResult(
    copied: copied,
    outputPath: destination is LocalFolder ? destination.path : '',
  );
}

Future<int> _copyIfPresent(
  StorageGateway gateway,
  StorageEntry file,
  FolderRef destination,
) async {
  try {
    await gateway.copyFile(
      file,
      destination,
      file.name,
      overwrite: true,
    );
    return 1;
  } on StorageException catch (e) {
    if (e.code == StorageException.notFound) return 0;
    rethrow;
  }
}

/// Creates a missing local export root after Task 03 classification.
///
/// Non-local / unclassified references fail closed with [invalid_arg].
/// Never constructs [File] / [Directory] from `content://`.
Future<void> _ensureLocalRoot(
  FolderRef folder,
  StorageGateway gateway,
) async {
  if (await gateway.exists(folder)) return;
  if (folder is! LocalFolder) {
    throw const StorageException(
      StorageException.invalidArg,
      'cannot create a non-local output folder',
    );
  }
  final classified = classifyLocalDirectoryPath(folder.path);
  if (classified == null || classified != folder.path) {
    throw const StorageException(
      StorageException.invalidArg,
      'refused non-local path',
    );
  }
  await Directory(folder.path).create(recursive: true);
}
