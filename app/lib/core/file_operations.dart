import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

enum FileOperationIntent { copy, move }

enum FileOperationStatus {
  copied,
  moved,
  skippedConflict,
  sourceMissing,
  accessDenied,
  unavailableProviderItem,
  insufficientStorage,
  cancelled,
  failed,
}

enum FileOperationDestinationState { notCommitted, committed, unknown }

enum FileOperationSourceState { retained, deleted, missing, changed, unknown }

enum FileOperationTemporaryState { none, cleaned, mayRemain }

enum FileOperationStage {
  planning,
  access,
  capability,
  pinSource,
  prepareDestination,
  exclusiveCopy,
  createTemporary,
  copyTemporary,
  verifyTemporary,
  promoteTemporary,
  deleteSource,
  inspectRecovery,
  cleanupTemporary,
  releaseAccess,
}

enum FileOperationRecoveryAction {
  chooseDifferentDestination,
  reselectSource,
  grantProviderAccess,
  makeProviderItemAvailable,
  freeStorage,
  reviewCompletedOperations,
  verifyDestination,
  verifySource,
  reviewMissingSource,
  preserveBothCopies,
  cleanTemporaryArtifact,
  reviewProviderAccess,
  reviewDestinationParent,
  reviewProviderError,
}

enum FileOperationSourceDeletionOutcome { deleted, changed, missing }

enum FileOperationSourcePinState { pinned, missing, changed }

enum FileOperationTemporaryDeletionOutcome {
  deleted,
  alreadyAbsent,
  identityChanged,
}

enum FileOperationDestinationPreparationOutcome { unchanged, created }

enum FileOperationDestinationParentState { unchanged, created, unknown }

/// Stable provider identity used only for comparison and plan hashing.
final class FileProviderIdentity {
  const FileProviderIdentity(this.value);

  final String value;
}

/// Stable provider-owned item identity used only for comparison and hashing.
final class FileProviderItemIdentity {
  const FileProviderItemIdentity(this.value);

  final String value;
}

/// A provider-owned selection locator that is resolved only inside a planning
/// access scope. The opaque locator is never copied into a plan.
final class FileProviderSelection {
  const FileProviderSelection({
    required this.providerIdentity,
    required this.opaqueLocator,
  });

  final FileProviderIdentity providerIdentity;
  final Object opaqueLocator;
}

/// Provider-validated single path component.
///
/// It cannot represent traversal, an absolute path, or either common path
/// separator, so planners never treat presentation text as a destination.
final class FileProviderItemName {
  FileProviderItemName.validated(String value) : value = _validate(value);

  final String value;

  static String _validate(String value) {
    if (value.isEmpty ||
        value == '.' ||
        value == '..' ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.contains('\u0000') ||
        RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      throw ArgumentError.value(value, 'value', 'Unsafe provider item name.');
    }
    return value;
  }
}

/// Non-authoritative, provider-issued breadcrumb used only for an in-memory
/// confirmation preview. Components are validated separately so this value can
/// never be reinterpreted as a provider locator or filesystem path.
final class FileOperationPreviewPath {
  FileOperationPreviewPath(Iterable<FileProviderItemName> components)
    : this._escaped(
        components.map((component) => _escapePreviewText(component.value)),
      );

  FileOperationPreviewPath._escaped(Iterable<String> components)
    : components = List.unmodifiable(components) {
    if (this.components.isEmpty) {
      throw ArgumentError.value(
        components,
        'components',
        'A preview breadcrumb must contain at least one component.',
      );
    }
  }

  factory FileOperationPreviewPath.single(FileProviderItemName name) {
    return FileOperationPreviewPath([name]);
  }

  FileOperationPreviewPath append(FileProviderItemName name) {
    return FileOperationPreviewPath._escaped([
      ...components,
      _escapePreviewText(name.value),
    ]);
  }

  /// Already-escaped display components. These are safe presentation text,
  /// never authoritative provider names or locators.
  final List<String> components;

  String get label => components.join('/');
}

String _escapePreviewText(String value) {
  final escaped = StringBuffer();
  for (final rune in value.runes) {
    switch (rune) {
      case 0x09:
        escaped.write(r'\t');
      case 0x0a:
        escaped.write(r'\n');
      case 0x0d:
        escaped.write(r'\r');
      default:
        if (_isUnsafePreviewRune(rune)) {
          escaped
            ..write(r'\u{')
            ..write(rune.toRadixString(16).toUpperCase().padLeft(4, '0'))
            ..write('}');
        } else {
          escaped.writeCharCode(rune);
        }
    }
  }
  return escaped.toString();
}

bool _isUnsafePreviewRune(int rune) {
  return rune <= 0x1f ||
      (rune >= 0x7f && rune <= 0x9f) ||
      rune == 0x00ad ||
      rune == 0x061c ||
      rune == 0x180e ||
      (rune >= 0x200b && rune <= 0x200f) ||
      (rune >= 0x2028 && rune <= 0x202e) ||
      (rune >= 0x2060 && rune <= 0x206f) ||
      rune == 0xfeff ||
      (rune >= 0xfff9 && rune <= 0xfffb);
}

/// Safe presentation metadata bound to the exact approved plan.
///
/// It is not authorization, must not be persisted as a provider reference,
/// and is deliberately separate from every opaque provider value.
final class FileOperationPreview {
  const FileOperationPreview({required this.source, required this.destination});

  final FileOperationPreviewPath source;
  final FileOperationPreviewPath destination;
}

/// Convenience adapter for the current local-path picker boundary.
///
/// Its path is ephemeral input to [DartFileOperationPlatform]. The planner
/// resolves it inside a planning scope and does not persist or log it.
abstract final class DartFileProviderSelection {
  static const providerIdentity = FileProviderIdentity('dart-io-local');

  static FileProviderSelection fromPath(String path) {
    return FileProviderSelection(
      providerIdentity: providerIdentity,
      opaqueLocator: path,
    );
  }
}

/// Durable, provider-owned operation reference.
///
/// [opaqueItem] is interpreted only by the provider adapter. [itemName] is a
/// provider-issued, validated single component and is never used for
/// authorization or stable identity.
final class FileProviderItemReference {
  FileProviderItemReference({
    required this.providerIdentity,
    required this.itemIdentity,
    required this.opaqueItem,
    required this.itemName,
    required this.previewPath,
  }) {
    final name = itemName;
    if (name != null &&
        previewPath.components.last != _escapePreviewText(name.value)) {
      throw ArgumentError.value(
        previewPath.label,
        'previewPath',
        'The provider preview leaf must match the authoritative item name.',
      );
    }
  }

  final FileProviderIdentity providerIdentity;
  final FileProviderItemIdentity itemIdentity;
  final String opaqueItem;
  final FileProviderItemName? itemName;
  final FileOperationPreviewPath previewPath;
}

final class FileProviderDirectoryEntry {
  FileProviderDirectoryEntry({required this.reference, required this.name}) {
    if (reference.itemName?.value != name.value) {
      throw ArgumentError.value(
        name.value,
        'name',
        'The directory entry name must match its authoritative reference.',
      );
    }
  }

  final FileProviderItemReference reference;
  final FileProviderItemName name;
}

final class FileOperationIssue {
  const FileOperationIssue({required this.stage, required this.status});

  final FileOperationStage stage;
  final FileOperationStatus status;
}

final class FileOperationRecovery {
  const FileOperationRecovery({required this.action, required this.guidance});

  final FileOperationRecoveryAction action;
  final String guidance;
}

final class FileOperationEffects {
  const FileOperationEffects({
    required this.destination,
    required this.source,
    required this.temporary,
    required this.destinationParent,
    this.temporaryArtifact,
  });

  final FileOperationDestinationState destination;
  final FileOperationSourceState source;
  final FileOperationTemporaryState temporary;
  final FileOperationDestinationParentState destinationParent;
  final FileOperationTemporaryArtifact? temporaryArtifact;
}

final class FileOperation {
  FileOperation._({
    required this.id,
    required this.source,
    required this.destination,
    required this.intent,
    required this.preview,
    this.preflightStatus,
    List<FileOperationIssue> preflightIssues = const [],
  }) : preflightIssues = List.unmodifiable(preflightIssues);

  factory FileOperation.create({
    required FileProviderItemReference source,
    required FileProviderItemReference destination,
    required FileOperationIntent intent,
  }) {
    return FileOperation._(
      id: stableFileOperationId(
        source: source,
        destination: destination,
        intent: intent,
      ),
      source: source,
      destination: destination,
      intent: intent,
      preview: FileOperationPreview(
        source: source.previewPath,
        destination: destination.previewPath,
      ),
    );
  }

  final String id;
  final FileProviderItemReference source;
  final FileProviderItemReference destination;
  final FileOperationIntent intent;
  final FileOperationPreview preview;
  final FileOperationStatus? preflightStatus;
  final List<FileOperationIssue> preflightIssues;

  FileOperation _withPreflight(
    FileOperationStatus? status,
    List<FileOperationIssue> issues,
  ) {
    return FileOperation._(
      id: id,
      source: source,
      destination: destination,
      intent: intent,
      preview: preview,
      preflightStatus: status,
      preflightIssues: issues,
    );
  }
}

final class FileOperationPlan {
  FileOperationPlan._(List<FileOperation> operations)
    : operations = List.unmodifiable(operations),
      digest = _planDigest(operations);

  final List<FileOperation> operations;
  final String digest;
  final Object _approvalIdentity = Object();
}

/// A synchronously claimed, one-shot authorization for one exact plan.
final class FileOperationApproval {
  FileOperationApproval.forPlan(FileOperationPlan plan)
    : _planIdentity = plan._approvalIdentity,
      _planDigest = plan.digest;

  final Object _planIdentity;
  final String _planDigest;
  bool _consumed = false;

  void claim(FileOperationPlan plan) {
    if (!identical(_planIdentity, plan._approvalIdentity) ||
        _planDigest != plan.digest) {
      throw const FileOperationApprovalMismatchException();
    }
    if (_consumed) throw const FileOperationApprovalConsumedException();
    _consumed = true;
  }
}

class FileOperationApprovalMismatchException implements Exception {
  const FileOperationApprovalMismatchException();
}

class FileOperationApprovalConsumedException implements Exception {
  const FileOperationApprovalConsumedException();
}

enum FileOperationExceptionOutcomeKind { general, promotion }

/// Provider error with explicit mutation effects.
///
/// Human/provider error text is intentionally not copied into results, where
/// it could accidentally disclose ephemeral provider paths.
final class FileOperationException implements Exception {
  factory FileOperationException(
    FileOperationStatus status, {
    FileOperationDestinationState destinationState =
        FileOperationDestinationState.notCommitted,
    FileOperationSourceState? sourceState,
    FileOperationTemporaryArtifact? temporaryArtifact,
    FileOperationDestinationParentState destinationParentState =
        FileOperationDestinationParentState.unchanged,
  }) {
    _validateErrorStatus(status);
    if (status == FileOperationStatus.skippedConflict &&
        destinationState != FileOperationDestinationState.notCommitted) {
      throw ArgumentError.value(
        status,
        'status',
        'A conflict cannot report a committed or unknown destination.',
      );
    }
    return FileOperationException._(
      status,
      destinationState: destinationState,
      sourceState: sourceState,
      temporaryConsumed: false,
      temporaryArtifact: temporaryArtifact,
      destinationParentState: destinationParentState,
      outcomeKind: FileOperationExceptionOutcomeKind.general,
    );
  }

  factory FileOperationException.promotionCommitted(
    FileOperationStatus status,
  ) {
    _validatePromotionStatus(status, allowsConflict: false);
    return FileOperationException._(
      status,
      destinationState: FileOperationDestinationState.committed,
      sourceState: null,
      temporaryConsumed: true,
      temporaryArtifact: null,
      destinationParentState: FileOperationDestinationParentState.unchanged,
      outcomeKind: FileOperationExceptionOutcomeKind.promotion,
    );
  }

  factory FileOperationException.promotionNotCommitted(
    FileOperationStatus status,
  ) {
    _validatePromotionStatus(status, allowsConflict: true);
    return FileOperationException._(
      status,
      destinationState: FileOperationDestinationState.notCommitted,
      sourceState: null,
      temporaryConsumed: false,
      temporaryArtifact: null,
      destinationParentState: FileOperationDestinationParentState.unchanged,
      outcomeKind: FileOperationExceptionOutcomeKind.promotion,
    );
  }

  factory FileOperationException.promotionUnknown(
    FileOperationStatus status, {
    required bool temporaryConsumed,
  }) {
    _validatePromotionStatus(status, allowsConflict: false);
    return FileOperationException._(
      status,
      destinationState: FileOperationDestinationState.unknown,
      sourceState: null,
      temporaryConsumed: temporaryConsumed,
      temporaryArtifact: null,
      destinationParentState: FileOperationDestinationParentState.unchanged,
      outcomeKind: FileOperationExceptionOutcomeKind.promotion,
    );
  }

  FileOperationException._(
    this.status, {
    required this.destinationState,
    required this.sourceState,
    required this.temporaryConsumed,
    required this.temporaryArtifact,
    required this.destinationParentState,
    required this.outcomeKind,
  });

  static void _validatePromotionStatus(
    FileOperationStatus status, {
    required bool allowsConflict,
  }) {
    _validateErrorStatus(status);
    if (!allowsConflict && status == FileOperationStatus.skippedConflict) {
      throw ArgumentError.value(
        status,
        'status',
        'A committed or unknown promotion cannot report a conflict.',
      );
    }
  }

  static void _validateErrorStatus(FileOperationStatus status) {
    if (status == FileOperationStatus.copied ||
        status == FileOperationStatus.moved) {
      throw ArgumentError.value(
        status,
        'status',
        'Provider exceptions must report an error status.',
      );
    }
  }

  final FileOperationStatus status;
  final FileOperationDestinationState destinationState;
  final FileOperationSourceState? sourceState;
  final bool temporaryConsumed;
  final FileOperationTemporaryArtifact? temporaryArtifact;
  final FileOperationDestinationParentState destinationParentState;
  final FileOperationExceptionOutcomeKind outcomeKind;
}

final class FileOperationResult {
  FileOperationResult._({
    required this.operation,
    required this.status,
    required this.effects,
    required List<FileOperationIssue> issues,
    required List<FileOperationRecovery> recovery,
  }) : issues = List.unmodifiable(issues),
       recovery = List.unmodifiable(recovery);

  final FileOperation operation;
  final FileOperationStatus status;
  final FileOperationEffects effects;
  final List<FileOperationIssue> issues;
  final List<FileOperationRecovery> recovery;

  String get recoveryGuidance => recovery.isEmpty
      ? 'No action needed.'
      : recovery.map((item) => item.guidance).join(' ');
}

final class FileOperationExecution {
  FileOperationExecution(List<FileOperationResult> results)
    : results = List.unmodifiable(results);

  final List<FileOperationResult> results;
}

enum DestinationPreflightDisposition {
  available,
  conflict,
  accessDenied,
  unavailableProviderItem,
  insufficientStorage,
  failed,
}

final class DestinationInspection {
  const DestinationInspection(this.disposition);

  final DestinationPreflightDisposition disposition;

  FileOperationStatus? get status => switch (disposition) {
    DestinationPreflightDisposition.available => null,
    DestinationPreflightDisposition.conflict =>
      FileOperationStatus.skippedConflict,
    DestinationPreflightDisposition.accessDenied =>
      FileOperationStatus.accessDenied,
    DestinationPreflightDisposition.unavailableProviderItem =>
      FileOperationStatus.unavailableProviderItem,
    DestinationPreflightDisposition.insufficientStorage =>
      FileOperationStatus.insufficientStorage,
    DestinationPreflightDisposition.failed => FileOperationStatus.failed,
  };
}

class FileOperationPlanningAccess {
  const FileOperationPlanningAccess({required this.opaqueAccess});

  final Object opaqueAccess;
}

class FileOperationAccess {
  const FileOperationAccess({
    required this.operationId,
    required this.sourceProviderIdentity,
    required this.destinationProviderIdentity,
    required this.opaqueAccess,
  });

  final String operationId;
  final FileProviderIdentity sourceProviderIdentity;
  final FileProviderIdentity destinationProviderIdentity;
  final Object opaqueAccess;

  bool authorizes(FileOperation operation) {
    return operationId == operation.id &&
        sourceProviderIdentity.value ==
            operation.source.providerIdentity.value &&
        destinationProviderIdentity.value ==
            operation.destination.providerIdentity.value;
  }
}

class PinnedSourceIdentity {
  const PinnedSourceIdentity({
    required this.reference,
    required this.revisionIdentity,
    required this.opaquePinnedSource,
  });

  final FileProviderItemReference reference;
  final FileProviderItemIdentity revisionIdentity;
  final Object opaquePinnedSource;
}

final class FileOperationSourcePinResult {
  const FileOperationSourcePinResult.pinned(PinnedSourceIdentity this.source)
    : state = FileOperationSourcePinState.pinned;

  const FileOperationSourcePinResult.missing()
    : state = FileOperationSourcePinState.missing,
      source = null;

  const FileOperationSourcePinResult.changed()
    : state = FileOperationSourcePinState.changed,
      source = null;

  final FileOperationSourcePinState state;
  final PinnedSourceIdentity? source;
}

final class FileOperationTemporaryArtifact {
  const FileOperationTemporaryArtifact({
    required this.operationId,
    required this.opaqueOriginalLocator,
    required this.opaqueIdentity,
  });

  final String operationId;
  final String opaqueOriginalLocator;
  final String opaqueIdentity;
}

class FileOperationTemporaryCopyReceipt {
  const FileOperationTemporaryCopyReceipt({
    required this.artifact,
    required this.opaqueReceipt,
  });

  final FileOperationTemporaryArtifact artifact;
  final Object opaqueReceipt;
}

class FileOperationDestinationReceipt {
  const FileOperationDestinationReceipt.committed({
    required this.operationId,
    required this.destinationIdentity,
    required this.opaqueReceipt,
  }) : destinationState = FileOperationDestinationState.committed;

  final String operationId;
  final FileProviderItemIdentity destinationIdentity;
  final FileOperationDestinationState destinationState;
  final Object opaqueReceipt;

  bool matches(FileOperation operation) {
    return destinationState == FileOperationDestinationState.committed &&
        operationId == operation.id &&
        destinationIdentity.value == operation.destination.itemIdentity.value;
  }
}

/// Provider boundary for planning and the complete mutation lifetime.
///
/// Task 3C can hold security-scoped access and file coordination inside the
/// opaque scope, pinned source, artifact, and receipt values. Core code never
/// re-resolves a path after planning.
abstract interface class FileOperationPlatform {
  /// Acquires the planning scope atomically. If acquisition cannot complete,
  /// the adapter must roll back every partially acquired provider lease before
  /// throwing.
  Future<FileOperationPlanningAccess> beginPlanningAccess();

  /// Attempts to release every lease held by [access], even when one release
  /// fails, then reports the combined failure.
  Future<void> endPlanningAccess(FileOperationPlanningAccess access);

  /// Resolves and registers the selected directory in this exact active scope.
  /// A genuinely missing prospective directory is allowed, but an existing
  /// non-directory or provider-colliding component must be rejected.
  Future<FileProviderItemReference> resolveDirectory(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  );

  /// Resolves and registers the selected file in this exact active scope after
  /// validating every required parent component under provider collision
  /// semantics. A genuinely missing prospective file is allowed.
  Future<FileProviderItemReference> resolveFile(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  );

  /// Requires [directory] to have been issued in this exact active scope before
  /// provider I/O, then registers every returned entry in the same scope.
  Future<List<FileProviderDirectoryEntry>> listDirectory(
    FileOperationPlanningAccess access,
    FileProviderItemReference directory,
  );

  /// Requires [directory] to have been issued in this exact active scope before
  /// provider I/O, then registers the returned child in the same scope.
  Future<FileProviderItemReference> resolveChild({
    required FileOperationPlanningAccess access,
    required FileProviderItemReference directory,
    required FileProviderItemName relativeName,
  });

  /// Requires both references to have been issued in this exact active scope
  /// before provider I/O.
  Future<bool> locationsEquivalent(
    FileOperationPlanningAccess access,
    FileProviderItemReference left,
    FileProviderItemReference right,
  );

  /// Non-consumingly confirms this exact authoritative-reference and
  /// safe-preview tuple was issued in [access]. Semantic or suffix equivalence
  /// is insufficient: planning rejects cloned, altered, and prior-scope tuples
  /// before approval.
  Future<bool> previewMetadataMatchesReference(
    FileOperationPlanningAccess access,
    FileProviderItemReference reference,
  );

  /// Pure collision identity for a reference already validated by planning;
  /// this method must not perform provider I/O or derive display authority.
  String destinationCollisionKey(FileProviderItemReference destination);

  /// Requires [destination] to have been issued in this exact active scope
  /// before provider I/O. Inspection validates the complete required
  /// destination-parent component chain, rejecting wrong-type and colliding
  /// components without creating any missing directory.
  Future<DestinationInspection> inspectDestination(
    FileOperationPlanningAccess access,
    FileProviderItemReference destination,
  );

  /// Acquires the complete source/destination operation scope. If acquisition
  /// cannot complete, the adapter must roll back every partially acquired
  /// provider lease before throwing.
  Future<FileOperationAccess> beginOperationAccess(FileOperation operation);

  /// Attempts to release every source and destination lease held by [access],
  /// even when one release fails, then reports the combined failure.
  Future<void> endOperationAccess(FileOperationAccess access);

  /// Must reject before any write if the complete operation is unsupported.
  Future<void> requireMutationCapability(
    FileOperationAccess access,
    FileOperation operation,
  );

  /// Authorizes only conditional cleanup of one previously owned temporary
  /// artifact. It must not authorize copy, move, promotion, or source deletion.
  Future<void> requireTemporaryCleanupCapability(
    FileOperationAccess access,
    FileOperation operation,
    FileOperationTemporaryArtifact temporary,
  );

  Future<FileOperationSourcePinResult> pinSource(
    FileOperationAccess access,
    FileProviderItemReference source,
  );

  Future<FileOperationDestinationPreparationOutcome> ensureDestinationParent(
    FileOperationAccess access,
    FileProviderItemReference destination,
  );

  /// One provider operation retaining an exclusive destination handle through
  /// write, flush, and close. It must clean its owned partial on failure.
  Future<FileOperationDestinationReceipt> copyToDestinationExclusively({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileProviderItemReference destination,
  });

  /// Creates a unique sibling owned by this operation. If an error occurs
  /// after creation, it must report that exact artifact in
  /// [FileOperationException.temporaryArtifact] so core can clean it.
  Future<FileOperationTemporaryArtifact> createTemporarySibling({
    required FileOperationAccess access,
    required FileProviderItemReference destination,
    required String operationId,
  });

  Future<FileOperationTemporaryCopyReceipt> copyToTemporary({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryArtifact temporary,
  });

  Future<void> verifyTemporaryCopy({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryCopyReceipt copy,
  });

  /// A single atomic no-replace promotion. A normal return means committed
  /// and the temporary artifact was consumed. An error must use one of the
  /// `FileOperationException.promotion*` factories; malformed/general errors
  /// fail closed with an unknown destination state.
  Future<FileOperationDestinationReceipt> promoteTemporaryWithoutReplacement({
    required FileOperationAccess access,
    required FileOperationTemporaryCopyReceipt copy,
    required FileProviderItemReference destination,
  });

  /// One coordinated conditional mutation bound to [source]'s pinned item and
  /// revision. It must never check and later delete by pathname.
  Future<FileOperationSourceDeletionOutcome> deleteSourceIfUnchanged({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
  });

  /// Conditionally deletes only the original temporary locator and identity.
  /// It must never follow the identity after an atomic rename/promotion.
  Future<FileOperationTemporaryDeletionOutcome> deleteTemporary({
    required FileOperationAccess access,
    required FileOperationTemporaryArtifact temporary,
  });

  Future<DestinationInspection> inspectDestinationDuringRecovery(
    FileOperationAccess access,
    FileProviderItemReference destination,
  );
}

final class _DartPlanningScope {
  final Set<FileProviderItemReference> issuedReferences =
      Set<FileProviderItemReference>.identity();
  final Map<FileProviderItemReference, List<String>> requiredDirectories =
      Map<FileProviderItemReference, List<String>>.identity();
  bool active = true;
}

_DartPlanningScope _dartPlanningScope(FileOperationPlanningAccess access) {
  final opaqueAccess = access.opaqueAccess;
  if (opaqueAccess is! _DartPlanningScope || !opaqueAccess.active) {
    throw StateError('Dart planning access is not active.');
  }
  return opaqueAccess;
}

FileProviderItemReference _issueDartReference(
  FileOperationPlanningAccess access,
  FileProviderItemReference reference, {
  required Iterable<String> requiredDirectories,
}) {
  final scope = _dartPlanningScope(access);
  scope
    ..issuedReferences.add(reference)
    ..requiredDirectories[reference] = List.unmodifiable(
      requiredDirectories.map(p.normalize),
    );
  return reference;
}

void _requireDartIssuedReference(
  FileOperationPlanningAccess access,
  FileProviderItemReference reference,
) {
  if (!_dartPlanningScope(access).issuedReferences.contains(reference)) {
    throw ArgumentError.value(
      reference.itemIdentity.value,
      'reference',
      'The provider reference was not issued in this planning scope.',
    );
  }
}

List<String> _dartRequiredDirectories(
  FileOperationPlanningAccess access,
  FileProviderItemReference reference,
) {
  _requireDartIssuedReference(access, reference);
  return _dartPlanningScope(access).requiredDirectories[reference]!;
}

List<String> _appendRequiredDirectory(List<String> existing, String directory) {
  final normalized = p.normalize(directory);
  if (existing.isNotEmpty && existing.last == normalized) return existing;
  return [...existing, normalized];
}

/// Portable planning adapter. Mutation fails at capability negotiation before
/// its first write because `dart:io` cannot retain an exclusive no-replace
/// destination handle or coordinated source identity for this contract.
class DartFileOperationPlatform implements FileOperationPlatform {
  const DartFileOperationPlatform();

  @override
  Future<FileOperationPlanningAccess> beginPlanningAccess() async {
    return FileOperationPlanningAccess(opaqueAccess: _DartPlanningScope());
  }

  @override
  Future<void> endPlanningAccess(FileOperationPlanningAccess access) async {
    final scope = _dartPlanningScope(access);
    scope
      ..active = false
      ..issuedReferences.clear()
      ..requiredDirectories.clear();
  }

  @override
  Future<FileProviderItemReference> resolveDirectory(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    _dartPlanningScope(access);
    final reference = await _resolveDartSelection(selection, isDirectory: true);
    final validation = await _inspectDartDirectoryChain(
      _dartDirectoryAncestors(reference.opaqueItem),
      collisionKey: destinationCollisionKey,
    );
    if (validation == _DartDirectoryChainState.conflict) {
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    return _issueDartReference(
      access,
      reference,
      requiredDirectories: [reference.opaqueItem],
    );
  }

  @override
  Future<FileProviderItemReference> resolveFile(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    _dartPlanningScope(access);
    final reference = await _resolveDartSelection(
      selection,
      isDirectory: false,
    );
    final parentPath = p.dirname(reference.opaqueItem);
    final validation = await _inspectDartDirectoryChain(
      _dartDirectoryAncestors(parentPath),
      collisionKey: destinationCollisionKey,
    );
    if (validation == _DartDirectoryChainState.conflict) {
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    final existingType = await FileSystemEntity.type(
      reference.opaqueItem,
      followLinks: true,
    );
    if (existingType == FileSystemEntityType.directory) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    return _issueDartReference(
      access,
      reference,
      requiredDirectories: [parentPath],
    );
  }

  @override
  Future<List<FileProviderDirectoryEntry>> listDirectory(
    FileOperationPlanningAccess access,
    FileProviderItemReference directory,
  ) async {
    final requiredDirectories = _dartRequiredDirectories(access, directory);
    final directoryPath = _dartPath(directory);
    final entries = <FileProviderDirectoryEntry>[];
    await for (final entity in Directory(
      directoryPath,
    ).list(recursive: false)) {
      if (entity is! File) continue;
      final name = FileProviderItemName.validated(p.basename(entity.path));
      final reference = await _dartReference(
        entity.path,
        isDirectory: false,
        previewPath: directory.previewPath.append(name),
      );
      entries.add(
        FileProviderDirectoryEntry(
          reference: _issueDartReference(
            access,
            reference,
            requiredDirectories: _appendRequiredDirectory(
              requiredDirectories,
              directoryPath,
            ),
          ),
          name: name,
        ),
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
    final requiredDirectories = _dartRequiredDirectories(access, directory);
    final directoryPath = _dartPath(directory);
    final childPath = p.normalize(p.join(directoryPath, relativeName.value));
    return _issueDartReference(
      access,
      await _dartReference(
        childPath,
        isDirectory: false,
        previewPath: directory.previewPath.append(relativeName),
      ),
      requiredDirectories: _appendRequiredDirectory(
        requiredDirectories,
        directoryPath,
      ),
    );
  }

  @override
  Future<bool> locationsEquivalent(
    FileOperationPlanningAccess access,
    FileProviderItemReference left,
    FileProviderItemReference right,
  ) async {
    _requireDartIssuedReference(access, left);
    _requireDartIssuedReference(access, right);
    return left.providerIdentity.value == right.providerIdentity.value &&
        left.itemIdentity.value == right.itemIdentity.value;
  }

  @override
  Future<bool> previewMetadataMatchesReference(
    FileOperationPlanningAccess access,
    FileProviderItemReference reference,
  ) async {
    final scope = _dartPlanningScope(access);
    if (!scope.issuedReferences.contains(reference)) return false;
    if (reference.providerIdentity.value !=
        DartFileProviderSelection.providerIdentity.value) {
      return false;
    }
    var cursor = _dartPath(reference);
    for (
      var index = reference.previewPath.components.length - 1;
      index >= 0;
      index--
    ) {
      final name = _validatedBaseName(cursor);
      if (name == null ||
          reference.previewPath.components[index] !=
              _escapePreviewText(name.value)) {
        return false;
      }
      cursor = p.dirname(cursor);
    }
    return true;
  }

  @override
  String destinationCollisionKey(FileProviderItemReference destination) {
    return '${destination.providerIdentity.value}:'
        '${destination.itemIdentity.value.toLowerCase()}';
  }

  @override
  Future<DestinationInspection> inspectDestination(
    FileOperationPlanningAccess access,
    FileProviderItemReference destination,
  ) {
    final requiredDirectories = _dartRequiredDirectories(access, destination);
    return _inspectDartDestination(
      destination,
      collisionKey: destinationCollisionKey,
      stage: FileOperationStage.planning,
      requiredDirectories: requiredDirectories,
    );
  }

  @override
  Future<FileOperationAccess> beginOperationAccess(
    FileOperation operation,
  ) async {
    return FileOperationAccess(
      operationId: operation.id,
      sourceProviderIdentity: operation.source.providerIdentity,
      destinationProviderIdentity: operation.destination.providerIdentity,
      opaqueAccess: Object(),
    );
  }

  @override
  Future<void> endOperationAccess(FileOperationAccess access) async {}

  @override
  Future<void> requireMutationCapability(
    FileOperationAccess access,
    FileOperation operation,
  ) {
    return _unsupportedMutation();
  }

  @override
  Future<void> requireTemporaryCleanupCapability(
    FileOperationAccess access,
    FileOperation operation,
    FileOperationTemporaryArtifact temporary,
  ) {
    return _unsupportedMutation();
  }

  @override
  Future<FileOperationSourcePinResult> pinSource(
    FileOperationAccess access,
    FileProviderItemReference source,
  ) async {
    final stat = await FileStat.stat(_dartPath(source));
    if (stat.type == FileSystemEntityType.notFound) {
      return const FileOperationSourcePinResult.missing();
    }
    return FileOperationSourcePinResult.pinned(
      PinnedSourceIdentity(
        reference: source,
        revisionIdentity: FileProviderItemIdentity(
          [
            '${stat.type}',
            stat.size,
            stat.modified.microsecondsSinceEpoch,
            stat.changed.microsecondsSinceEpoch,
          ].join(':'),
        ),
        opaquePinnedSource: Object(),
      ),
    );
  }

  @override
  Future<FileOperationDestinationPreparationOutcome> ensureDestinationParent(
    FileOperationAccess access,
    FileProviderItemReference destination,
  ) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<FileOperationDestinationReceipt> copyToDestinationExclusively({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileProviderItemReference destination,
  }) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<FileOperationTemporaryArtifact> createTemporarySibling({
    required FileOperationAccess access,
    required FileProviderItemReference destination,
    required String operationId,
  }) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<FileOperationTemporaryCopyReceipt> copyToTemporary({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryArtifact temporary,
  }) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<void> verifyTemporaryCopy({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryCopyReceipt copy,
  }) {
    return _unsupportedMutation();
  }

  @override
  Future<FileOperationDestinationReceipt> promoteTemporaryWithoutReplacement({
    required FileOperationAccess access,
    required FileOperationTemporaryCopyReceipt copy,
    required FileProviderItemReference destination,
  }) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<FileOperationSourceDeletionOutcome> deleteSourceIfUnchanged({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
  }) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<FileOperationTemporaryDeletionOutcome> deleteTemporary({
    required FileOperationAccess access,
    required FileOperationTemporaryArtifact temporary,
  }) async {
    await _unsupportedMutation();
    throw StateError('unreachable');
  }

  @override
  Future<DestinationInspection> inspectDestinationDuringRecovery(
    FileOperationAccess access,
    FileProviderItemReference destination,
  ) {
    return _inspectDartDestination(
      destination,
      collisionKey: destinationCollisionKey,
      stage: FileOperationStage.inspectRecovery,
    );
  }
}

typedef FileOperationBuilder =
    Future<List<FileOperation>> Function(FileOperationPlanningAccess access);

/// Builds and validates a plan under one planning access scope, then releases
/// that scope before the immutable plan is returned for preview.
Future<FileOperationPlan> planFileOperations({
  required FileOperationBuilder buildOperations,
  FileOperationPlatform platform = const DartFileOperationPlatform(),
}) async {
  final access = await platform.beginPlanningAccess();
  try {
    final operations = List<FileOperation>.of(await buildOperations(access));
    final identifiers = <String>{};
    for (final operation in operations) {
      final sourcePreviewMatches = await platform
          .previewMetadataMatchesReference(access, operation.source);
      final destinationPreviewMatches = await platform
          .previewMetadataMatchesReference(access, operation.destination);
      if (!sourcePreviewMatches || !destinationPreviewMatches) {
        throw ArgumentError.value(
          operation.id,
          'operations',
          'Provider preview metadata does not match its authoritative item.',
        );
      }
      if (!identifiers.add(operation.id)) {
        throw ArgumentError.value(
          operation.id,
          'operations',
          'Operation IDs must be unique.',
        );
      }
    }

    final planned = <FileOperation>[];
    final destinationIndices = <String, List<int>>{};
    for (final operation in operations) {
      FileOperationStatus? status;
      final issues = <FileOperationIssue>[];
      try {
        status = (await platform.inspectDestination(
          access,
          operation.destination,
        )).status;
      } on Object catch (error) {
        status = _statusForError(error, stage: FileOperationStage.planning);
        issues.add(
          FileOperationIssue(
            stage: FileOperationStage.planning,
            status: status,
          ),
        );
      }
      planned.add(operation._withPreflight(status, issues));
      final key = platform.destinationCollisionKey(operation.destination);
      (destinationIndices[key] ??= <int>[]).add(planned.length - 1);
    }

    for (final indices in destinationIndices.values) {
      if (indices.length < 2) continue;
      for (final index in indices) {
        final existing = planned[index];
        planned[index] = existing._withPreflight(
          existing.preflightStatus ?? FileOperationStatus.skippedConflict,
          [
            ...existing.preflightIssues,
            const FileOperationIssue(
              stage: FileOperationStage.planning,
              status: FileOperationStatus.skippedConflict,
            ),
          ],
        );
      }
    }
    return FileOperationPlan._(planned);
  } finally {
    await platform.endPlanningAccess(access);
  }
}

Future<FileOperationExecution> executeFileOperationPlan(
  FileOperationPlan plan, {
  required FileOperationApproval approval,
  FileOperationPlatform platform = const DartFileOperationPlatform(),
  bool Function()? shouldCancel,
}) async {
  // This synchronous claim is deliberately before the first await or provider
  // access, so one approval can never start two executions.
  approval.claim(plan);

  final results = <FileOperationResult>[];
  for (var index = 0; index < plan.operations.length; index++) {
    if (shouldCancel?.call() ?? false) {
      for (final operation in plan.operations.skip(index)) {
        results.add(
          _notExecutedResult(operation, FileOperationStatus.cancelled),
        );
      }
      break;
    }
    final operation = plan.operations[index];
    final result = operation.preflightStatus != null
        ? _preflightResult(operation)
        : await _executeOperation(
            operation,
            platform,
            shouldCancel: shouldCancel,
          );
    results.add(result);
    final cancellationWasReported =
        result.status == FileOperationStatus.cancelled ||
        result.issues.any(
          (issue) => issue.status == FileOperationStatus.cancelled,
        );
    if (cancellationWasReported) {
      for (final remaining in plan.operations.skip(index + 1)) {
        results.add(
          _notExecutedResult(remaining, FileOperationStatus.cancelled),
        );
      }
      break;
    }
  }
  return FileOperationExecution(results);
}

/// Retries cleanup from an unforgeable core result while preserving the
/// original operation's source, destination, and parent effects.
Future<FileOperationResult> recoverTemporaryArtifact(
  FileOperationResult continuation, {
  FileOperationPlatform platform = const DartFileOperationPlatform(),
}) async {
  final operation = continuation.operation;
  final artifact = continuation.effects.temporaryArtifact;
  if (continuation.effects.temporary != FileOperationTemporaryState.mayRemain ||
      artifact == null ||
      artifact.operationId != operation.id) {
    throw ArgumentError.value(
      continuation,
      'continuation',
      'Result has no valid temporary cleanup continuation.',
    );
  }

  FileOperationAccess? access;
  var stage = FileOperationStage.access;
  var temporaryState = FileOperationTemporaryState.mayRemain;
  FileOperationTemporaryArtifact? retainedArtifact = artifact;
  final issues = <FileOperationIssue>[...continuation.issues];

  try {
    access = await platform.beginOperationAccess(operation);
    if (!access.authorizes(operation)) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    stage = FileOperationStage.capability;
    await platform.requireTemporaryCleanupCapability(
      access,
      operation,
      artifact,
    );
    stage = FileOperationStage.cleanupTemporary;
    final deletion = await platform.deleteTemporary(
      access: access,
      temporary: artifact,
    );
    switch (deletion) {
      case FileOperationTemporaryDeletionOutcome.deleted:
      case FileOperationTemporaryDeletionOutcome.alreadyAbsent:
        temporaryState = FileOperationTemporaryState.cleaned;
        retainedArtifact = null;
        issues.removeWhere(
          (issue) => issue.stage == FileOperationStage.cleanupTemporary,
        );
      case FileOperationTemporaryDeletionOutcome.identityChanged:
        issues.add(
          const FileOperationIssue(
            stage: FileOperationStage.cleanupTemporary,
            status: FileOperationStatus.failed,
          ),
        );
    }
  } on Object catch (error) {
    issues.add(
      FileOperationIssue(
        stage: stage,
        status: _statusForError(error, stage: stage),
      ),
    );
  }

  if (access != null) {
    try {
      await platform.endOperationAccess(access);
    } on Object catch (error) {
      issues.add(
        FileOperationIssue(
          stage: FileOperationStage.releaseAccess,
          status: _statusForError(
            error,
            stage: FileOperationStage.releaseAccess,
          ),
        ),
      );
    }
  }

  return _buildResult(
    operation: operation,
    status: continuation.status,
    destinationState: continuation.effects.destination,
    sourceState: continuation.effects.source,
    temporaryState: temporaryState,
    temporaryArtifact: retainedArtifact,
    destinationParentState: continuation.effects.destinationParent,
    issues: issues,
  );
}

Future<FileOperationResult> _executeOperation(
  FileOperation operation,
  FileOperationPlatform platform, {
  bool Function()? shouldCancel,
}) async {
  FileOperationAccess? access;
  FileOperationTemporaryArtifact? temporary;
  var stage = FileOperationStage.access;
  var status = FileOperationStatus.failed;
  var destinationState = FileOperationDestinationState.notCommitted;
  var sourceState = FileOperationSourceState.unknown;
  var temporaryState = FileOperationTemporaryState.none;
  var destinationParentState = FileOperationDestinationParentState.unchanged;
  var mutationAttempted = false;
  final issues = <FileOperationIssue>[];

  try {
    access = await platform.beginOperationAccess(operation);
    if (!access.authorizes(operation)) {
      throw FileOperationException(FileOperationStatus.failed);
    }

    stage = FileOperationStage.capability;
    await platform.requireMutationCapability(access, operation);

    stage = FileOperationStage.pinSource;
    final pin = await platform.pinSource(access, operation.source);
    if (pin.state == FileOperationSourcePinState.missing) {
      sourceState = FileOperationSourceState.missing;
      status = FileOperationStatus.sourceMissing;
      issues.add(
        const FileOperationIssue(
          stage: FileOperationStage.pinSource,
          status: FileOperationStatus.sourceMissing,
        ),
      );
    } else if (pin.state == FileOperationSourcePinState.changed) {
      sourceState = FileOperationSourceState.changed;
      status = FileOperationStatus.failed;
      issues.add(
        const FileOperationIssue(
          stage: FileOperationStage.pinSource,
          status: FileOperationStatus.failed,
        ),
      );
    } else {
      final pinnedSource = pin.source!;
      if (!_sameProviderReference(pinnedSource.reference, operation.source)) {
        throw FileOperationException(FileOperationStatus.failed);
      }
      sourceState = FileOperationSourceState.retained;
      _throwIfCancelled(shouldCancel);
      stage = FileOperationStage.prepareDestination;
      final preparation = await platform.ensureDestinationParent(
        access,
        operation.destination,
      );
      destinationParentState = switch (preparation) {
        FileOperationDestinationPreparationOutcome.unchanged =>
          FileOperationDestinationParentState.unchanged,
        FileOperationDestinationPreparationOutcome.created =>
          FileOperationDestinationParentState.created,
      };

      if (operation.intent == FileOperationIntent.copy) {
        _throwIfCancelled(shouldCancel);
        stage = FileOperationStage.exclusiveCopy;
        mutationAttempted = true;
        final receipt = await platform.copyToDestinationExclusively(
          access: access,
          source: pinnedSource,
          destination: operation.destination,
        );
        if (!receipt.matches(operation)) {
          throw FileOperationException(
            FileOperationStatus.failed,
            destinationState: FileOperationDestinationState.unknown,
          );
        }
        destinationState = FileOperationDestinationState.committed;
        status = FileOperationStatus.copied;
      } else {
        _throwIfCancelled(shouldCancel);
        stage = FileOperationStage.createTemporary;
        mutationAttempted = true;
        final createdTemporary = await platform.createTemporarySibling(
          access: access,
          destination: operation.destination,
          operationId: operation.id,
        );
        if (createdTemporary.operationId != operation.id) {
          throw FileOperationException(FileOperationStatus.failed);
        }
        temporary = createdTemporary;

        _throwIfCancelled(shouldCancel);
        stage = FileOperationStage.copyTemporary;
        final copy = await platform.copyToTemporary(
          access: access,
          source: pinnedSource,
          temporary: temporary,
        );
        if (copy.artifact.operationId != operation.id ||
            copy.artifact.opaqueOriginalLocator !=
                temporary.opaqueOriginalLocator ||
            copy.artifact.opaqueIdentity != temporary.opaqueIdentity) {
          throw FileOperationException(FileOperationStatus.failed);
        }

        _throwIfCancelled(shouldCancel);
        stage = FileOperationStage.verifyTemporary;
        await platform.verifyTemporaryCopy(
          access: access,
          source: pinnedSource,
          copy: copy,
        );

        _throwIfCancelled(shouldCancel);
        stage = FileOperationStage.promoteTemporary;
        final receipt = await platform.promoteTemporaryWithoutReplacement(
          access: access,
          copy: copy,
          destination: operation.destination,
        );
        if (!receipt.matches(operation)) {
          throw FileOperationException(
            FileOperationStatus.failed,
            destinationState: FileOperationDestinationState.unknown,
          );
        }
        destinationState = FileOperationDestinationState.committed;
        temporary = null;

        _throwIfCancelled(shouldCancel);
        stage = FileOperationStage.deleteSource;
        final deletion = await platform.deleteSourceIfUnchanged(
          access: access,
          source: pinnedSource,
        );
        switch (deletion) {
          case FileOperationSourceDeletionOutcome.deleted:
            sourceState = FileOperationSourceState.deleted;
            status = FileOperationStatus.moved;
          case FileOperationSourceDeletionOutcome.changed:
            sourceState = FileOperationSourceState.changed;
            status = FileOperationStatus.failed;
            issues.add(
              const FileOperationIssue(
                stage: FileOperationStage.deleteSource,
                status: FileOperationStatus.failed,
              ),
            );
          case FileOperationSourceDeletionOutcome.missing:
            sourceState = FileOperationSourceState.missing;
            status = FileOperationStatus.failed;
            issues.add(
              const FileOperationIssue(
                stage: FileOperationStage.deleteSource,
                status: FileOperationStatus.sourceMissing,
              ),
            );
        }
      }
    }
  } on _FileOperationCancellation {
    status = FileOperationStatus.cancelled;
    issues.add(
      FileOperationIssue(stage: stage, status: FileOperationStatus.cancelled),
    );
  } on Object catch (error) {
    status = _statusForError(error, stage: stage);
    if (error is FileOperationException) {
      final isValidPromotionOutcome =
          stage == FileOperationStage.promoteTemporary &&
          error.outcomeKind == FileOperationExceptionOutcomeKind.promotion;
      final reportedDestinationState = switch (stage) {
        FileOperationStage.exclusiveCopy
            when error.outcomeKind ==
                FileOperationExceptionOutcomeKind.general =>
          error.destinationState,
        FileOperationStage.exclusiveCopy =>
          FileOperationDestinationState.unknown,
        FileOperationStage.promoteTemporary when isValidPromotionOutcome =>
          error.destinationState,
        FileOperationStage.promoteTemporary =>
          FileOperationDestinationState.unknown,
        _ => destinationState,
      };
      destinationState = _mergeDestinationState(
        destinationState,
        reportedDestinationState,
      );
      if (stage == FileOperationStage.deleteSource) {
        sourceState = error.sourceState ?? FileOperationSourceState.unknown;
      }
      if (stage == FileOperationStage.createTemporary &&
          error.temporaryArtifact != null) {
        final reportedTemporary = error.temporaryArtifact!;
        if (reportedTemporary.operationId == operation.id) {
          temporary ??= reportedTemporary;
        }
      }
      if (stage == FileOperationStage.prepareDestination) {
        destinationParentState = _mergeDestinationParentState(
          destinationParentState,
          error.destinationParentState,
        );
      }
      if (isValidPromotionOutcome && error.temporaryConsumed) {
        temporary = null;
      }
    } else {
      if (stage == FileOperationStage.exclusiveCopy ||
          stage == FileOperationStage.promoteTemporary) {
        // An untyped provider failure at a commit-capable boundary cannot be
        // assumed to precede commit. Never downgrade it to a mere conflict.
        destinationState = FileOperationDestinationState.unknown;
      }
      if (stage == FileOperationStage.deleteSource) {
        sourceState = FileOperationSourceState.unknown;
      }
      if (stage == FileOperationStage.prepareDestination) {
        destinationParentState = FileOperationDestinationParentState.unknown;
      }
    }
    issues.add(FileOperationIssue(stage: stage, status: status));

    if (mutationAttempted &&
        access != null &&
        status != FileOperationStatus.skippedConflict &&
        destinationState != FileOperationDestinationState.committed) {
      try {
        final inspection = await platform.inspectDestinationDuringRecovery(
          access,
          operation.destination,
        );
        if (inspection.status case final recoveryStatus?) {
          issues.add(
            FileOperationIssue(
              stage: FileOperationStage.inspectRecovery,
              status: recoveryStatus,
            ),
          );
        }
      } on Object catch (recoveryError) {
        issues.add(
          FileOperationIssue(
            stage: FileOperationStage.inspectRecovery,
            status: _statusForError(
              recoveryError,
              stage: FileOperationStage.inspectRecovery,
            ),
          ),
        );
      }
    }
  }

  // Cleanup and access release are deliberately independent. A cleanup error
  // cannot suppress release, and neither can erase already-committed effects.
  if (temporary != null && access != null) {
    try {
      final deletion = await platform.deleteTemporary(
        access: access,
        temporary: temporary,
      );
      switch (deletion) {
        case FileOperationTemporaryDeletionOutcome.deleted:
        case FileOperationTemporaryDeletionOutcome.alreadyAbsent:
          temporaryState = FileOperationTemporaryState.cleaned;
          temporary = null;
        case FileOperationTemporaryDeletionOutcome.identityChanged:
          temporaryState = FileOperationTemporaryState.mayRemain;
          status = FileOperationStatus.failed;
          issues.add(
            const FileOperationIssue(
              stage: FileOperationStage.cleanupTemporary,
              status: FileOperationStatus.failed,
            ),
          );
      }
    } on Object catch (error) {
      temporaryState = FileOperationTemporaryState.mayRemain;
      status = FileOperationStatus.failed;
      issues.add(
        FileOperationIssue(
          stage: FileOperationStage.cleanupTemporary,
          status: _statusForError(
            error,
            stage: FileOperationStage.cleanupTemporary,
          ),
        ),
      );
    }
  }

  if (access != null) {
    try {
      await platform.endOperationAccess(access);
    } on Object catch (error) {
      status = FileOperationStatus.failed;
      issues.add(
        FileOperationIssue(
          stage: FileOperationStage.releaseAccess,
          status: _statusForError(
            error,
            stage: FileOperationStage.releaseAccess,
          ),
        ),
      );
    }
  }

  return _buildResult(
    operation: operation,
    status: status,
    destinationState: destinationState,
    sourceState: sourceState,
    temporaryState: temporaryState,
    temporaryArtifact: temporary,
    destinationParentState: destinationParentState,
    issues: issues,
  );
}

void _throwIfCancelled(bool Function()? shouldCancel) {
  if (shouldCancel?.call() ?? false) {
    throw const _FileOperationCancellation();
  }
}

final class _FileOperationCancellation implements Exception {
  const _FileOperationCancellation();
}

FileOperationResult _preflightResult(FileOperation operation) {
  return _buildResult(
    operation: operation,
    status: operation.preflightStatus!,
    destinationState: FileOperationDestinationState.notCommitted,
    sourceState: FileOperationSourceState.unknown,
    temporaryState: FileOperationTemporaryState.none,
    temporaryArtifact: null,
    destinationParentState: FileOperationDestinationParentState.unchanged,
    issues: operation.preflightIssues,
  );
}

FileOperationResult _notExecutedResult(
  FileOperation operation,
  FileOperationStatus status,
) {
  return _buildResult(
    operation: operation,
    status: status,
    destinationState: FileOperationDestinationState.notCommitted,
    sourceState: FileOperationSourceState.unknown,
    temporaryState: FileOperationTemporaryState.none,
    temporaryArtifact: null,
    destinationParentState: FileOperationDestinationParentState.unchanged,
    issues: const [],
  );
}

FileOperationResult _buildResult({
  required FileOperation operation,
  required FileOperationStatus status,
  required FileOperationDestinationState destinationState,
  required FileOperationSourceState sourceState,
  required FileOperationTemporaryState temporaryState,
  required FileOperationTemporaryArtifact? temporaryArtifact,
  required FileOperationDestinationParentState destinationParentState,
  required List<FileOperationIssue> issues,
}) {
  final recovery = <FileOperationRecovery>[];

  void addRecovery(FileOperationRecoveryAction action, String guidance) {
    if (recovery.any((item) => item.action == action)) return;
    recovery.add(FileOperationRecovery(action: action, guidance: guidance));
  }

  switch (destinationState) {
    case FileOperationDestinationState.committed:
      if (operation.intent == FileOperationIntent.move) {
        switch (sourceState) {
          case FileOperationSourceState.retained:
          case FileOperationSourceState.changed:
            addRecovery(
              FileOperationRecoveryAction.preserveBothCopies,
              'The destination is committed and the source remains; preserve '
              'both copies until the retained or changed source is reviewed.',
            );
          case FileOperationSourceState.unknown:
            addRecovery(
              FileOperationRecoveryAction.verifySource,
              'The destination is committed but source state is unknown; '
              'verify the source before retrying.',
            );
          case FileOperationSourceState.missing:
            addRecovery(
              FileOperationRecoveryAction.reviewMissingSource,
              'The destination is committed and the pinned source is no longer '
              'present; review the provider history before retrying.',
            );
          case FileOperationSourceState.deleted:
            break;
        }
      }
    case FileOperationDestinationState.unknown:
      addRecovery(
        FileOperationRecoveryAction.verifyDestination,
        'Destination commit state is unknown; verify it before retrying.',
      );
    case FileOperationDestinationState.notCommitted:
      break;
  }

  if (temporaryState == FileOperationTemporaryState.mayRemain) {
    addRecovery(
      FileOperationRecoveryAction.cleanTemporaryArtifact,
      'A provider-owned temporary artifact may remain and needs review.',
    );
  }
  if (destinationParentState == FileOperationDestinationParentState.unknown ||
      (destinationParentState == FileOperationDestinationParentState.created &&
          destinationState != FileOperationDestinationState.committed)) {
    addRecovery(
      FileOperationRecoveryAction.reviewDestinationParent,
      'Destination parent directories may have been created and need review.',
    );
  }
  if (issues.any((issue) => issue.stage == FileOperationStage.releaseAccess)) {
    addRecovery(
      FileOperationRecoveryAction.reviewProviderAccess,
      'Provider access release failed and needs review.',
    );
  }

  void addStatusRecovery(FileOperationStatus value) {
    switch (value) {
      case FileOperationStatus.copied:
      case FileOperationStatus.moved:
      case FileOperationStatus.failed:
        break;
      case FileOperationStatus.skippedConflict:
        addRecovery(
          FileOperationRecoveryAction.chooseDifferentDestination,
          'Choose a different destination; the existing item was preserved.',
        );
      case FileOperationStatus.sourceMissing:
        addRecovery(
          FileOperationRecoveryAction.reselectSource,
          'Reselect the source item and create a new plan.',
        );
      case FileOperationStatus.accessDenied:
        addRecovery(
          FileOperationRecoveryAction.grantProviderAccess,
          'Grant provider access and create a new plan.',
        );
      case FileOperationStatus.unavailableProviderItem:
        addRecovery(
          FileOperationRecoveryAction.makeProviderItemAvailable,
          'Make the provider item available and create a new plan.',
        );
      case FileOperationStatus.insufficientStorage:
        addRecovery(
          FileOperationRecoveryAction.freeStorage,
          'Free destination storage and create a new plan.',
        );
      case FileOperationStatus.cancelled:
        addRecovery(
          FileOperationRecoveryAction.reviewCompletedOperations,
          'Review completed operations before creating a new plan.',
        );
    }
  }

  for (final issue in issues) {
    addStatusRecovery(issue.status);
  }
  addStatusRecovery(status);
  final hasPrimaryFailedIssue = issues.any(
    (issue) =>
        issue.status == FileOperationStatus.failed &&
        issue.stage != FileOperationStage.cleanupTemporary &&
        issue.stage != FileOperationStage.releaseAccess &&
        issue.stage != FileOperationStage.inspectRecovery,
  );
  if (status == FileOperationStatus.failed &&
      (issues.isEmpty || hasPrimaryFailedIssue)) {
    addRecovery(
      FileOperationRecoveryAction.reviewProviderError,
      'Review the provider error and confirmed effects before retrying.',
    );
  }

  return FileOperationResult._(
    operation: operation,
    status: status,
    effects: FileOperationEffects(
      destination: destinationState,
      source: sourceState,
      temporary: temporaryState,
      temporaryArtifact: temporaryArtifact,
      destinationParent: destinationParentState,
    ),
    issues: issues,
    recovery: recovery,
  );
}

FileOperationStatus _statusForError(Object error, {FileOperationStage? stage}) {
  if (error is FileOperationException) {
    if (error.status == FileOperationStatus.skippedConflict) {
      final validExclusiveCopyConflict =
          stage == FileOperationStage.exclusiveCopy &&
          error.outcomeKind == FileOperationExceptionOutcomeKind.general &&
          error.destinationState == FileOperationDestinationState.notCommitted;
      final validPromotionConflict =
          stage == FileOperationStage.promoteTemporary &&
          error.outcomeKind == FileOperationExceptionOutcomeKind.promotion &&
          error.destinationState == FileOperationDestinationState.notCommitted;
      if (!validExclusiveCopyConflict && !validPromotionConflict) {
        return FileOperationStatus.failed;
      }
    }
    if (error.status == FileOperationStatus.sourceMissing &&
        stage != FileOperationStage.pinSource &&
        stage != FileOperationStage.deleteSource) {
      return FileOperationStatus.failed;
    }
    return error.status;
  }
  if (error is FileSystemException) {
    final code = error.osError?.errorCode;
    if (code == 28) return FileOperationStatus.insufficientStorage;
    if (code == 1 || code == 13 || code == 30) {
      return FileOperationStatus.accessDenied;
    }
    if (code == 2 &&
        (stage == FileOperationStage.pinSource ||
            stage == FileOperationStage.deleteSource)) {
      return FileOperationStatus.sourceMissing;
    }
  }
  return FileOperationStatus.failed;
}

FileOperationDestinationState _mergeDestinationState(
  FileOperationDestinationState known,
  FileOperationDestinationState reported,
) {
  if (known == FileOperationDestinationState.committed ||
      reported == FileOperationDestinationState.committed) {
    return FileOperationDestinationState.committed;
  }
  if (known == FileOperationDestinationState.unknown ||
      reported == FileOperationDestinationState.unknown) {
    return FileOperationDestinationState.unknown;
  }
  return FileOperationDestinationState.notCommitted;
}

FileOperationDestinationParentState _mergeDestinationParentState(
  FileOperationDestinationParentState known,
  FileOperationDestinationParentState reported,
) {
  if (known == FileOperationDestinationParentState.created ||
      reported == FileOperationDestinationParentState.created) {
    return FileOperationDestinationParentState.created;
  }
  if (known == FileOperationDestinationParentState.unknown ||
      reported == FileOperationDestinationParentState.unknown) {
    return FileOperationDestinationParentState.unknown;
  }
  return FileOperationDestinationParentState.unchanged;
}

bool _sameProviderReference(
  FileProviderItemReference left,
  FileProviderItemReference right,
) {
  return left.providerIdentity.value == right.providerIdentity.value &&
      left.itemIdentity.value == right.itemIdentity.value &&
      left.opaqueItem == right.opaqueItem;
}

Future<void> _unsupportedMutation() async {
  throw FileOperationException(FileOperationStatus.failed);
}

Future<FileProviderItemReference> _resolveDartSelection(
  FileProviderSelection selection, {
  required bool isDirectory,
}) async {
  if (selection.providerIdentity.value !=
          DartFileProviderSelection.providerIdentity.value ||
      selection.opaqueLocator is! String) {
    throw FileOperationException(FileOperationStatus.unavailableProviderItem);
  }
  return _dartReference(
    selection.opaqueLocator as String,
    isDirectory: isDirectory,
  );
}

Future<FileProviderItemReference> _dartReference(
  String path, {
  required bool isDirectory,
  FileOperationPreviewPath? previewPath,
}) async {
  final absolute = p.normalize(File(path).absolute.path);
  var identity = absolute;
  try {
    identity = isDirectory
        ? await Directory(absolute).resolveSymbolicLinks()
        : await File(absolute).resolveSymbolicLinks();
  } on FileSystemException {
    // A not-yet-created destination keeps its normalized absolute identity.
  }
  final itemName = _validatedBaseName(absolute);
  return FileProviderItemReference(
    providerIdentity: DartFileProviderSelection.providerIdentity,
    itemIdentity: FileProviderItemIdentity(p.normalize(identity)),
    opaqueItem: absolute,
    itemName: itemName,
    previewPath:
        previewPath ??
        FileOperationPreviewPath.single(
          itemName ?? FileProviderItemName.validated('Selected location'),
        ),
  );
}

FileProviderItemName? _validatedBaseName(String path) {
  try {
    return FileProviderItemName.validated(p.basename(path));
  } on ArgumentError {
    return null;
  }
}

String _dartPath(FileProviderItemReference reference) {
  if (reference.providerIdentity.value !=
      DartFileProviderSelection.providerIdentity.value) {
    throw FileOperationException(FileOperationStatus.unavailableProviderItem);
  }
  return reference.opaqueItem;
}

Future<DestinationInspection> _inspectDartDestination(
  FileProviderItemReference destination, {
  required String Function(FileProviderItemReference) collisionKey,
  required FileOperationStage stage,
  List<String>? requiredDirectories,
}) async {
  try {
    final targetPath = _dartPath(destination);
    if (await FileSystemEntity.type(targetPath, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return const DestinationInspection(
        DestinationPreflightDisposition.conflict,
      );
    }
    final directoryState = await _inspectDartDirectoryChain(
      requiredDirectories ?? _dartDirectoryAncestors(p.dirname(targetPath)),
      collisionKey: collisionKey,
    );
    switch (directoryState) {
      case _DartDirectoryChainState.conflict:
        return const DestinationInspection(
          DestinationPreflightDisposition.conflict,
        );
      case _DartDirectoryChainState.missing:
        return const DestinationInspection(
          DestinationPreflightDisposition.available,
        );
      case _DartDirectoryChainState.exact:
        break;
    }
    final parent = Directory(p.dirname(targetPath));
    final desiredKey = collisionKey(destination);
    await for (final entity in parent.list(recursive: false)) {
      final entityType = await FileSystemEntity.type(
        entity.path,
        followLinks: true,
      );
      final reference = await _dartReference(
        entity.path,
        isDirectory: entityType == FileSystemEntityType.directory,
      );
      if (collisionKey(reference) == desiredKey) {
        return const DestinationInspection(
          DestinationPreflightDisposition.conflict,
        );
      }
    }
    return const DestinationInspection(
      DestinationPreflightDisposition.available,
    );
  } on FileSystemException catch (error) {
    return DestinationInspection(
      _preflightDispositionForStatus(_statusForError(error, stage: stage)),
    );
  }
}

enum _DartDirectoryChainState { exact, missing, conflict }

List<String> _dartDirectoryAncestors(String directoryPath) {
  final paths = <String>[];
  var cursor = p.normalize(File(directoryPath).absolute.path);
  while (true) {
    paths.add(cursor);
    final parent = p.dirname(cursor);
    if (parent == cursor) break;
    cursor = parent;
  }
  return paths.reversed.toList(growable: false);
}

Future<_DartDirectoryChainState> _inspectDartDirectoryChain(
  Iterable<String> requiredDirectories, {
  required String Function(FileProviderItemReference) collisionKey,
}) async {
  for (final rawDirectoryPath in requiredDirectories) {
    final directoryPath = p.normalize(File(rawDirectoryPath).absolute.path);
    final parentPath = p.dirname(directoryPath);
    if (parentPath == directoryPath) {
      final rootType = await FileSystemEntity.type(
        directoryPath,
        followLinks: true,
      );
      if (rootType != FileSystemEntityType.directory) {
        return _DartDirectoryChainState.conflict;
      }
      continue;
    }

    final desired = await _dartReference(directoryPath, isDirectory: true);
    final desiredKey = collisionKey(desired);
    FileSystemEntityType? exactType;
    var collidingSibling = false;
    await for (final entity in Directory(parentPath).list(recursive: false)) {
      final entityPath = p.normalize(entity.path);
      final entityType = await FileSystemEntity.type(
        entity.path,
        followLinks: true,
      );
      final reference = await _dartReference(
        entity.path,
        isDirectory: entityType == FileSystemEntityType.directory,
      );
      if (entityPath == directoryPath) {
        exactType = entityType;
      } else if (collisionKey(reference) == desiredKey) {
        collidingSibling = true;
      }
    }
    if (collidingSibling) return _DartDirectoryChainState.conflict;
    if (exactType == null) return _DartDirectoryChainState.missing;
    if (exactType != FileSystemEntityType.directory) {
      return _DartDirectoryChainState.conflict;
    }
  }
  return _DartDirectoryChainState.exact;
}

DestinationPreflightDisposition _preflightDispositionForStatus(
  FileOperationStatus status,
) {
  return switch (status) {
    FileOperationStatus.skippedConflict =>
      DestinationPreflightDisposition.conflict,
    FileOperationStatus.accessDenied =>
      DestinationPreflightDisposition.accessDenied,
    FileOperationStatus.unavailableProviderItem =>
      DestinationPreflightDisposition.unavailableProviderItem,
    FileOperationStatus.insufficientStorage =>
      DestinationPreflightDisposition.insufficientStorage,
    FileOperationStatus.copied ||
    FileOperationStatus.moved ||
    FileOperationStatus.sourceMissing ||
    FileOperationStatus.cancelled ||
    FileOperationStatus.failed => DestinationPreflightDisposition.failed,
  };
}

String stableFileOperationId({
  required FileProviderItemReference source,
  required FileProviderItemReference destination,
  required FileOperationIntent intent,
}) {
  return 'op-v2-${_sha256OfLengthPrefixedFields(['file-operation-v2', intent.name, source.providerIdentity.value, source.itemIdentity.value, destination.providerIdentity.value, destination.itemIdentity.value])}';
}

String _planDigest(List<FileOperation> operations) {
  return _sha256OfLengthPrefixedFields([
    'file-operation-plan-v1',
    for (final operation in operations) ...[
      operation.id,
      operation.preflightStatus?.name ?? '',
      'source-preview',
      '${operation.preview.source.components.length}',
      for (final component in operation.preview.source.components) component,
      'destination-preview',
      '${operation.preview.destination.components.length}',
      for (final component in operation.preview.destination.components)
        component,
      for (final issue in operation.preflightIssues) ...[
        issue.stage.name,
        issue.status.name,
      ],
    ],
  ]);
}

String _sha256OfLengthPrefixedFields(List<String> fields) {
  final bytes = BytesBuilder(copy: false);
  for (final field in fields) {
    final encoded = utf8.encode(field);
    final length = ByteData(8)..setUint64(0, encoded.length, Endian.big);
    bytes
      ..add(length.buffer.asUint8List())
      ..add(encoded);
  }
  return sha256.convert(bytes.takeBytes()).toString();
}
