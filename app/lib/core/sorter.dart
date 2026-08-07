import 'dart:io';

import 'package:path/path.dart' as p;

import 'constants.dart';
import 'file_operations.dart';
import 'models.dart';

/// Produces a non-mutating plan under a balanced provider planning scope.
/// Task 3B must preview and explicitly approve the returned plan.
Future<FileOperationPlan> planSortPhotos({
  required FileProviderSelection input,
  required FileProviderSelection output,
  FileOperationPlatform platform = const DartFileOperationPlatform(),
}) {
  return planFileOperations(
    platform: platform,
    buildOperations: (access) async {
      final inputDirectory = await platform.resolveDirectory(access, input);
      final outputDirectory = await platform.resolveDirectory(access, output);
      final sameDirectory = await platform.locationsEquivalent(
        access,
        inputDirectory,
        outputDirectory,
      );
      final entries = await platform.listDirectory(access, inputDirectory);
      final supported =
          entries.where((entry) {
            final extension = p.extension(entry.name.value).toLowerCase();
            return rawExtensions.contains(extension) ||
                jpgExtensions.contains(extension);
          }).toList()..sort((left, right) {
            final nameOrder = left.name.value.compareTo(right.name.value);
            if (nameOrder != 0) return nameOrder;
            return left.reference.itemIdentity.value.compareTo(
              right.reference.itemIdentity.value,
            );
          });

      final operations = <FileOperation>[];
      for (final entry in supported) {
        final extension = p.extension(entry.name.value).toLowerCase();
        final folderName = rawExtensions.contains(extension) ? 'RAW' : 'JPG';
        final folder = await platform.resolveChild(
          access: access,
          directory: outputDirectory,
          relativeName: FileProviderItemName.validated(folderName),
        );
        final destination = await platform.resolveChild(
          access: access,
          directory: folder,
          relativeName: entry.name,
        );
        operations.add(
          FileOperation.create(
            source: entry.reference,
            destination: destination,
            intent: sameDirectory
                ? FileOperationIntent.move
                : FileOperationIntent.copy,
          ),
        );
      }
      return operations;
    },
  );
}

/// Legacy direct mutation is intentionally unavailable until Task 3B wires
/// preview/confirmation and Task 3C provides safe provider capabilities.
Future<SortResult> sortPhotos({
  required Directory input,
  required Directory output,
  void Function(SortProgress)? onProgress,
  bool Function()? shouldCancel,
}) async {
  throw UnsupportedError(
    'Task 3B preview and explicit approval are required before sorting.',
  );
}
