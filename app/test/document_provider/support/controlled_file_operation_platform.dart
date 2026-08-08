import 'dart:async';

import 'package:photo_sorter/core/file_operations.dart';

final class ControlledFileOperationPlatform implements FileOperationPlatform {
  ControlledFileOperationPlatform({
    this.capabilityFailure,
    this.capabilityError,
    this.mutationGate,
    this.acceptDartSelections = false,
    this.temporaryCopyFailure = false,
    this.retainTemporaryOnInitialCleanup = false,
    this.cleanupGate,
  });

  static const providerIdentity = FileProviderIdentity(
    'controlled-workflow-provider',
  );

  final FileOperationStatus? capabilityFailure;
  final Object? capabilityError;
  final Completer<void>? mutationGate;
  final bool acceptDartSelections;
  final bool temporaryCopyFailure;
  final bool retainTemporaryOnInitialCleanup;
  final Completer<void>? cleanupGate;

  final List<String> events = [];
  final Map<String, String> _files = {};
  final Map<String, DestinationPreflightDisposition> _inspections = {};
  final Map<Object, Set<FileProviderItemReference>> _planningScopes = {};
  final Map<String, String> _temporaries = {};

  int beginOperationCount = 0;
  int endOperationCount = 0;
  int exclusiveCopyCount = 0;
  int cleanupCount = 0;
  final Completer<void> mutationStarted = Completer<void>();
  final Completer<void> cleanupStarted = Completer<void>();
  final Completer<void> recoveryCleanupStarted = Completer<void>();

  FileProviderSelection selection(
    String id, {
    List<String>? previewComponents,
  }) {
    return FileProviderSelection(
      providerIdentity: providerIdentity,
      opaqueLocator: _ControlledLocator(
        id,
        previewComponents ?? [id.split('/').last],
      ),
    );
  }

  void addFile(String id, String contents) {
    _files[id] = contents;
  }

  void setInspection(String id, DestinationPreflightDisposition disposition) {
    _inspections[id] = disposition;
  }

  bool contains(String id) => _files.containsKey(id);

  String? contents(String id) => _files[id];

  @override
  Future<FileOperationPlanningAccess> beginPlanningAccess() async {
    final token = Object();
    _planningScopes[token] = Set<FileProviderItemReference>.identity();
    return FileOperationPlanningAccess(opaqueAccess: token);
  }

  @override
  Future<void> endPlanningAccess(FileOperationPlanningAccess access) async {
    _planningScopes.remove(access.opaqueAccess);
  }

  @override
  Future<FileProviderItemReference> resolveDirectory(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    return _issue(access, selection);
  }

  @override
  Future<FileProviderItemReference> resolveFile(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    return _issue(access, selection);
  }

  @override
  Future<List<FileProviderDirectoryEntry>> listDirectory(
    FileOperationPlanningAccess access,
    FileProviderItemReference directory,
  ) async {
    _requireIssued(access, directory);
    final directoryId = directory.opaqueItem.replaceAll('\\', '/');
    final prefix = directoryId.endsWith('/') ? directoryId : '$directoryId/';
    final entries = <FileProviderDirectoryEntry>[];
    for (final fileId in _files.keys) {
      final normalizedFileId = fileId.replaceAll('\\', '/');
      if (!normalizedFileId.startsWith(prefix)) continue;
      final name = normalizedFileId.substring(prefix.length);
      if (name.isEmpty || name.contains('/')) continue;
      final itemName = FileProviderItemName.validated(name);
      final reference = FileProviderItemReference(
        providerIdentity: directory.providerIdentity,
        itemIdentity: FileProviderItemIdentity(fileId),
        opaqueItem: fileId,
        itemName: itemName,
        previewPath: directory.previewPath.append(itemName),
      );
      _scope(access).add(reference);
      entries.add(
        FileProviderDirectoryEntry(reference: reference, name: itemName),
      );
    }
    return entries;
  }

  @override
  Future<FileProviderItemReference> resolveChild({
    required FileOperationPlanningAccess access,
    required FileProviderItemReference directory,
    required FileProviderItemName relativeName,
  }) async {
    _requireIssued(access, directory);
    final id = '${directory.opaqueItem}/${relativeName.value}';
    final reference = FileProviderItemReference(
      providerIdentity: directory.providerIdentity,
      itemIdentity: FileProviderItemIdentity(id),
      opaqueItem: id,
      itemName: relativeName,
      previewPath: directory.previewPath.append(relativeName),
    );
    _scope(access).add(reference);
    return reference;
  }

  @override
  Future<bool> locationsEquivalent(
    FileOperationPlanningAccess access,
    FileProviderItemReference left,
    FileProviderItemReference right,
  ) async {
    _requireIssued(access, left);
    _requireIssued(access, right);
    return left.itemIdentity.value == right.itemIdentity.value;
  }

  @override
  Future<bool> previewMetadataMatchesReference(
    FileOperationPlanningAccess access,
    FileProviderItemReference reference,
  ) async {
    return _scope(access).contains(reference);
  }

  @override
  String destinationCollisionKey(FileProviderItemReference destination) {
    return destination.itemIdentity.value.toLowerCase();
  }

  @override
  Future<DestinationInspection> inspectDestination(
    FileOperationPlanningAccess access,
    FileProviderItemReference destination,
  ) async {
    _requireIssued(access, destination);
    final disposition =
        _inspections[destination.itemIdentity.value] ??
        (_files.containsKey(destination.itemIdentity.value)
            ? DestinationPreflightDisposition.conflict
            : DestinationPreflightDisposition.available);
    return DestinationInspection(disposition);
  }

  @override
  Future<FileOperationAccess> beginOperationAccess(
    FileOperation operation,
  ) async {
    beginOperationCount++;
    events.add('begin:${operation.id}');
    return FileOperationAccess(
      operationId: operation.id,
      sourceProviderIdentity: operation.source.providerIdentity,
      destinationProviderIdentity: operation.destination.providerIdentity,
      opaqueAccess: Object(),
    );
  }

  @override
  Future<void> endOperationAccess(FileOperationAccess access) async {
    endOperationCount++;
    events.add('end:${access.operationId}');
  }

  @override
  Future<void> requireMutationCapability(
    FileOperationAccess access,
    FileOperation operation,
  ) async {
    events.add('capability:${operation.id}');
    final rawError = capabilityError;
    if (rawError != null) throw rawError;
    final failure = capabilityFailure;
    if (failure != null) throw FileOperationException(failure);
  }

  @override
  Future<void> requireTemporaryCleanupCapability(
    FileOperationAccess access,
    FileOperation operation,
    FileOperationTemporaryArtifact temporary,
  ) async {
    events.add('cleanup-capability:${operation.id}');
  }

  @override
  Future<FileOperationSourcePinResult> pinSource(
    FileOperationAccess access,
    FileProviderItemReference source,
  ) async {
    final contents = _files[source.itemIdentity.value];
    if (contents == null) return const FileOperationSourcePinResult.missing();
    return FileOperationSourcePinResult.pinned(
      PinnedSourceIdentity(
        reference: source,
        revisionIdentity: FileProviderItemIdentity(
          '${source.itemIdentity.value}:${contents.length}:$contents',
        ),
        opaquePinnedSource: _PinnedContents(contents),
      ),
    );
  }

  @override
  Future<FileOperationDestinationPreparationOutcome> ensureDestinationParent(
    FileOperationAccess access,
    FileProviderItemReference destination,
  ) async {
    return FileOperationDestinationPreparationOutcome.unchanged;
  }

  @override
  Future<FileOperationDestinationReceipt> copyToDestinationExclusively({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileProviderItemReference destination,
  }) async {
    exclusiveCopyCount++;
    events.add('copy:${access.operationId}');
    await _waitForMutationGate();
    final id = destination.itemIdentity.value;
    if (_files.containsKey(id)) {
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    _files[id] = (source.opaquePinnedSource as _PinnedContents).value;
    return FileOperationDestinationReceipt.committed(
      operationId: access.operationId,
      destinationIdentity: destination.itemIdentity,
      opaqueReceipt: Object(),
    );
  }

  @override
  Future<FileOperationTemporaryArtifact> createTemporarySibling({
    required FileOperationAccess access,
    required FileProviderItemReference destination,
    required String operationId,
  }) async {
    events.add('create-temp:$operationId');
    final locator = 'temporary:$operationId';
    _temporaries[locator] = '';
    return FileOperationTemporaryArtifact(
      operationId: operationId,
      opaqueOriginalLocator: locator,
      opaqueIdentity: 'identity:$operationId',
    );
  }

  @override
  Future<FileOperationTemporaryCopyReceipt> copyToTemporary({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryArtifact temporary,
  }) async {
    events.add('copy-temp:${access.operationId}');
    await _waitForMutationGate();
    _temporaries[temporary.opaqueOriginalLocator] =
        (source.opaquePinnedSource as _PinnedContents).value;
    if (temporaryCopyFailure) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    return FileOperationTemporaryCopyReceipt(
      artifact: temporary,
      opaqueReceipt: Object(),
    );
  }

  @override
  Future<void> verifyTemporaryCopy({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryCopyReceipt copy,
  }) async {
    final expected = (source.opaquePinnedSource as _PinnedContents).value;
    if (_temporaries[copy.artifact.opaqueOriginalLocator] != expected) {
      throw FileOperationException(FileOperationStatus.failed);
    }
  }

  @override
  Future<FileOperationDestinationReceipt> promoteTemporaryWithoutReplacement({
    required FileOperationAccess access,
    required FileOperationTemporaryCopyReceipt copy,
    required FileProviderItemReference destination,
  }) async {
    final destinationId = destination.itemIdentity.value;
    if (_files.containsKey(destinationId)) {
      throw FileOperationException.promotionNotCommitted(
        FileOperationStatus.skippedConflict,
      );
    }
    final contents = _temporaries.remove(copy.artifact.opaqueOriginalLocator);
    if (contents == null) {
      throw FileOperationException.promotionNotCommitted(
        FileOperationStatus.failed,
      );
    }
    _files[destinationId] = contents;
    return FileOperationDestinationReceipt.committed(
      operationId: access.operationId,
      destinationIdentity: destination.itemIdentity,
      opaqueReceipt: Object(),
    );
  }

  @override
  Future<FileOperationSourceDeletionOutcome> deleteSourceIfUnchanged({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
  }) async {
    final id = source.reference.itemIdentity.value;
    final expected = (source.opaquePinnedSource as _PinnedContents).value;
    if (!_files.containsKey(id)) {
      return FileOperationSourceDeletionOutcome.missing;
    }
    if (_files[id] != expected) {
      return FileOperationSourceDeletionOutcome.changed;
    }
    _files.remove(id);
    return FileOperationSourceDeletionOutcome.deleted;
  }

  @override
  Future<FileOperationTemporaryDeletionOutcome> deleteTemporary({
    required FileOperationAccess access,
    required FileOperationTemporaryArtifact temporary,
  }) async {
    cleanupCount++;
    if (!cleanupStarted.isCompleted) cleanupStarted.complete();
    if (retainTemporaryOnInitialCleanup && cleanupCount == 1) {
      return FileOperationTemporaryDeletionOutcome.identityChanged;
    }
    if (!recoveryCleanupStarted.isCompleted) {
      recoveryCleanupStarted.complete();
    }
    final gate = cleanupGate;
    if (gate != null) await gate.future;
    final removed = _temporaries.remove(temporary.opaqueOriginalLocator);
    return removed == null
        ? FileOperationTemporaryDeletionOutcome.alreadyAbsent
        : FileOperationTemporaryDeletionOutcome.deleted;
  }

  @override
  Future<DestinationInspection> inspectDestinationDuringRecovery(
    FileOperationAccess access,
    FileProviderItemReference destination,
  ) async {
    return DestinationInspection(
      _files.containsKey(destination.itemIdentity.value)
          ? DestinationPreflightDisposition.conflict
          : DestinationPreflightDisposition.available,
    );
  }

  FileProviderItemReference _issue(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) {
    final _ControlledLocator locator;
    if (selection.providerIdentity.value == providerIdentity.value &&
        selection.opaqueLocator is _ControlledLocator) {
      locator = selection.opaqueLocator as _ControlledLocator;
    } else if (acceptDartSelections &&
        selection.providerIdentity.value ==
            DartFileProviderSelection.providerIdentity.value &&
        selection.opaqueLocator is String) {
      final id = selection.opaqueLocator as String;
      final normalized = id.replaceAll('\\', '/');
      final components = normalized
          .split('/')
          .where((component) => component.isNotEmpty)
          .toList(growable: false);
      locator = _ControlledLocator(id, [
        components.isEmpty ? 'Selected Folder' : components.last,
      ]);
    } else {
      throw FileOperationException(FileOperationStatus.accessDenied);
    }
    final names = locator.previewComponents
        .map(FileProviderItemName.validated)
        .toList(growable: false);
    final reference = FileProviderItemReference(
      providerIdentity: selection.providerIdentity,
      itemIdentity: FileProviderItemIdentity(locator.id),
      opaqueItem: locator.id,
      itemName: names.last,
      previewPath: FileOperationPreviewPath(names),
    );
    _scope(access).add(reference);
    return reference;
  }

  Set<FileProviderItemReference> _scope(FileOperationPlanningAccess access) {
    final scope = _planningScopes[access.opaqueAccess];
    if (scope == null) {
      throw FileOperationException(FileOperationStatus.accessDenied);
    }
    return scope;
  }

  void _requireIssued(
    FileOperationPlanningAccess access,
    FileProviderItemReference reference,
  ) {
    if (!_scope(access).contains(reference)) {
      throw FileOperationException(FileOperationStatus.accessDenied);
    }
  }

  Future<void> _waitForMutationGate() async {
    if (!mutationStarted.isCompleted) mutationStarted.complete();
    final gate = mutationGate;
    if (gate != null) await gate.future;
  }
}

final class _ControlledLocator {
  const _ControlledLocator(this.id, this.previewComponents);

  final String id;
  final List<String> previewComponents;
}

final class _PinnedContents {
  const _PinnedContents(this.value);

  final String value;
}
