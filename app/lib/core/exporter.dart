import 'dart:io';

import 'cull_session.dart';
import 'file_operations.dart';
import 'models.dart';

class KeptPhotoExportSelection {
  const KeptPhotoExportSelection({
    required this.stem,
    required this.raw,
    this.jpg,
  });

  final String stem;
  final FileProviderSelection raw;
  final FileProviderSelection? jpg;
}

/// Produces a non-mutating kept-photo export plan under one balanced provider
/// planning scope. Task 3B must preview and explicitly approve the plan.
Future<FileOperationPlan> planKeptPhotoExport({
  required FileProviderSelection destination,
  required List<KeptPhotoExportSelection> pairs,
  required CullSession session,
  required bool includeJpgs,
  FileOperationPlatform platform = const DartFileOperationPlatform(),
}) {
  return planFileOperations(
    platform: platform,
    buildOperations: (access) async {
      final destinationDirectory = await platform.resolveDirectory(
        access,
        destination,
      );
      final operations = <FileOperation>[];

      Future<void> addCopy(FileProviderSelection selection) async {
        final source = await platform.resolveFile(access, selection);
        final sourceName = source.itemName;
        if (sourceName == null) {
          throw FileOperationException(
            FileOperationStatus.unavailableProviderItem,
          );
        }
        final target = await platform.resolveChild(
          access: access,
          directory: destinationDirectory,
          relativeName: sourceName,
        );
        operations.add(
          FileOperation.create(
            source: source,
            destination: target,
            intent: FileOperationIntent.copy,
          ),
        );
      }

      for (final pair in pairs) {
        if (session.flagFor(pair.stem) != CullFlag.keep) continue;
        await addCopy(pair.raw);
        if (includeJpgs && pair.jpg != null) await addCopy(pair.jpg!);
      }
      operations.sort((left, right) {
        final collisionOrder = platform
            .destinationCollisionKey(left.destination)
            .compareTo(platform.destinationCollisionKey(right.destination));
        if (collisionOrder != 0) return collisionOrder;
        return left.id.compareTo(right.id);
      });
      return operations;
    },
  );
}

/// Legacy direct mutation is intentionally unavailable until Task 3B wires
/// preview/confirmation and Task 3C provides safe provider capabilities.
Future<ExportResult> exportKept({
  required Directory source,
  required Directory destination,
  required List<PhotoPair> pairs,
  required CullSession session,
  required bool includeJpgs,
}) async {
  throw UnsupportedError(
    'Task 3B preview and explicit approval are required before exporting.',
  );
}
