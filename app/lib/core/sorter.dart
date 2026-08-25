import 'dart:io';

import 'constants.dart';
import 'folder_ref.dart';
import 'models.dart';
import 'storage/storage_gateway.dart';
import '../services/local_path_classifier.dart';

/// Sorts RAW and JPG files from [input] into [output]/RAW/ and [output]/JPG/.
///
/// When [input] and [output] resolve to the same folder, files are MOVED;
/// otherwise they are COPIED (originals are preserved).
///
/// Files that already exist at the destination are skipped (not overwritten).
/// Non-RAW, non-JPG files are left untouched.
///
/// Returns a [SortResult] describing what happened. If no RAW or JPG files
/// are found, returns a result with rawCount=0, jpgCount=0, skipped=0.
Future<SortResult> sortPhotos({
  required FolderRef input,
  required FolderRef output,
  required StorageGateway gateway,
  void Function(SortProgress)? onProgress,
  bool Function()? shouldCancel,
}) async {
  await _ensureLocalRoot(output, gateway);

  final sameDir = await gateway.isSameFolder(input, output);

  final files = <StorageEntry>[];
  final children = await gateway.listChildren(input);
  for (final entry in children) {
    if (entry.isDirectory) continue;
    if (isRaw(entry.name) || isJpg(entry.name)) {
      files.add(entry);
    }
  }

  final total = files.length;

  if (total == 0) {
    return SortResult(
      rawCount: 0,
      jpgCount: 0,
      skipped: 0,
      moved: sameDir,
      outputPath: _localOutputPath(output),
    );
  }

  int rawCount = 0;
  int jpgCount = 0;
  int skipped = 0;
  int processed = 0;
  bool wasCancelled = false;

  for (final file in files) {
    if (shouldCancel != null && shouldCancel()) {
      wasCancelled = true;
      break;
    }

    final isRawFile = isRaw(file.name);
    final destChild = isRawFile ? 'RAW' : 'JPG';
    await _ensureChildDirectory(gateway, output, destChild);

    processed++;
    onProgress?.call(SortProgress(
      current: processed,
      total: total,
      fileName: file.name,
    ));

    final dest = await gateway.childByName(
      output,
      file.name,
      parentDocumentId: destChild,
    );
    if (dest != null) {
      skipped++;
      continue;
    }

    if (sameDir) {
      final outcome = await gateway.moveFile(
        file,
        output,
        file.name,
        destParentDocumentId: destChild,
      );
      if (outcome != MoveOutcome.renamed &&
          outcome != MoveOutcome.copiedAndDeleted) {
        throw StorageException(
          StorageException.ioFailure,
          'in-place sort did not remove the source',
          {'name': file.name, 'outcome': outcome.name},
        );
      }
    } else {
      await gateway.copyFile(
        file,
        output,
        file.name,
        destParentDocumentId: destChild,
        overwrite: false,
      );
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
    outputPath: _localOutputPath(output),
    cancelled: wasCancelled,
  );
}

String _localOutputPath(FolderRef folder) {
  if (folder is LocalFolder) return folder.path;
  return '';
}

/// Creates a missing local output root after Task 03 classification.
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

/// Idempotent child-directory create for `RAW/` and `JPG/`.
Future<void> _ensureChildDirectory(
  StorageGateway gateway,
  FolderRef folder,
  String name,
) async {
  final existing = await gateway.childByName(folder, name);
  if (existing != null) {
    if (existing.isDirectory) return;
    throw StorageException(
      StorageException.alreadyExists,
      'destination is not a directory',
      {'name': name},
    );
  }
  try {
    await gateway.createDirectory(folder, name);
  } on StorageException catch (e) {
    if (e.code != StorageException.alreadyExists) rethrow;
  }
}
