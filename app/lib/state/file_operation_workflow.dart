import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/file_operations.dart';

enum FileOperationWorkflowPhase {
  idle,
  planning,
  preview,
  executing,
  completed,
  cancelled,
  error,
}

final class FileOperationBackend {
  const FileOperationBackend({
    required this.platform,
    required this.canExecute,
    required this.unavailableMessage,
  });

  final FileOperationPlatform platform;
  final bool canExecute;
  final String unavailableMessage;
}

final fileOperationBackendProvider = Provider<FileOperationBackend>((ref) {
  return const FileOperationBackend(
    platform: DartFileOperationPlatform(),
    canExecute: false,
    unavailableMessage:
        'This version can preview file changes but cannot apply them yet. '
        'No files were changed.',
  );
});

final class FileOperationWorkflowState {
  FileOperationWorkflowState({
    this.phase = FileOperationWorkflowPhase.idle,
    this.plan,
    this.execution,
    List<FileOperationResult> reportedResults = const [],
    this.completed = 0,
    this.total = 0,
    this.message,
    this.executionAvailable = false,
    this.cleanupOperationId,
  }) : reportedResults = List.unmodifiable(reportedResults);

  final FileOperationWorkflowPhase phase;
  final FileOperationPlan? plan;
  final FileOperationExecution? execution;
  final List<FileOperationResult> reportedResults;
  final int completed;
  final int total;
  final String? message;
  final bool executionAvailable;
  final String? cleanupOperationId;

  int get executableCount =>
      plan?.operations
          .where((operation) => operation.preflightStatus == null)
          .length ??
      0;

  int get blockedCount =>
      plan?.operations
          .where((operation) => operation.preflightStatus != null)
          .length ??
      0;

  bool get canConfirm =>
      phase == FileOperationWorkflowPhase.preview &&
      executionAvailable &&
      executableCount > 0;

  bool get isTerminal =>
      phase == FileOperationWorkflowPhase.completed ||
      phase == FileOperationWorkflowPhase.cancelled ||
      phase == FileOperationWorkflowPhase.error;

  bool get isActive =>
      phase != FileOperationWorkflowPhase.idle || cleanupOperationId != null;

  FileOperationWorkflowState copyWith({
    FileOperationWorkflowPhase? phase,
    Object? plan = _sentinel,
    Object? execution = _sentinel,
    List<FileOperationResult>? reportedResults,
    int? completed,
    int? total,
    Object? message = _sentinel,
    bool? executionAvailable,
    Object? cleanupOperationId = _sentinel,
  }) {
    return FileOperationWorkflowState(
      phase: phase ?? this.phase,
      plan: plan == _sentinel ? this.plan : plan as FileOperationPlan?,
      execution: execution == _sentinel
          ? this.execution
          : execution as FileOperationExecution?,
      reportedResults: reportedResults ?? this.reportedResults,
      completed: completed ?? this.completed,
      total: total ?? this.total,
      message: message == _sentinel ? this.message : message as String?,
      executionAvailable: executionAvailable ?? this.executionAvailable,
      cleanupOperationId: cleanupOperationId == _sentinel
          ? this.cleanupOperationId
          : cleanupOperationId as String?,
    );
  }

  static const _sentinel = Object();
}

class FileOperationWorkflowController
    extends Notifier<FileOperationWorkflowState> {
  FileOperationBackend? _plannedBackend;
  FileOperationBackend? _executionBackend;
  FileOperationExecution? _currentExecution;
  int _generation = 0;
  bool _cancelRequested = false;

  @override
  FileOperationWorkflowState build() {
    ref.onDispose(() {
      _generation++;
      _cancelRequested = true;
      _plannedBackend = null;
      _executionBackend = null;
      _currentExecution = null;
    });
    return FileOperationWorkflowState();
  }

  Future<void> prepare(
    Future<FileOperationPlan> Function(FileOperationPlatform platform)
    buildPlan,
  ) async {
    if (state.phase == FileOperationWorkflowPhase.executing ||
        state.cleanupOperationId != null) {
      return;
    }
    final generation = ++_generation;
    final backend = ref.read(fileOperationBackendProvider);
    _cancelRequested = false;
    _plannedBackend = null;
    _executionBackend = null;
    _currentExecution = null;
    state = FileOperationWorkflowState(
      phase: FileOperationWorkflowPhase.planning,
    );
    try {
      final plan = await buildPlan(backend.platform);
      if (!_isCurrent(generation)) return;
      _plannedBackend = backend;
      state = FileOperationWorkflowState(
        phase: FileOperationWorkflowPhase.preview,
        plan: plan,
        total: plan.operations.length,
        executionAvailable: backend.canExecute,
        message: backend.canExecute ? null : backend.unavailableMessage,
      );
    } on Object {
      if (!_isCurrent(generation)) return;
      _plannedBackend = null;
      state = FileOperationWorkflowState(
        phase: FileOperationWorkflowPhase.error,
        message: 'Could not prepare a file preview. No files were changed.',
      );
    }
  }

  Future<void> confirm() async {
    final plan = state.plan;
    if (state.phase != FileOperationWorkflowPhase.preview ||
        plan == null ||
        state.executableCount == 0) {
      return;
    }
    final plannedBackend = _plannedBackend;
    final currentBackend = ref.read(fileOperationBackendProvider);
    if (plannedBackend == null ||
        !plannedBackend.canExecute ||
        !currentBackend.canExecute ||
        !identical(plannedBackend.platform, currentBackend.platform)) {
      state = state.copyWith(
        executionAvailable: false,
        message: currentBackend.unavailableMessage,
      );
      return;
    }

    final generation = _generation;
    _cancelRequested = false;
    state = state.copyWith(
      phase: FileOperationWorkflowPhase.executing,
      execution: null,
      reportedResults: const [],
      completed: 0,
      total: plan.operations.length,
      message: 'Applying approved file changes…',
      cleanupOperationId: null,
    );

    try {
      final approval = FileOperationApproval.forPlan(plan);
      final execution = await executeFileOperationPlan(
        plan,
        approval: approval,
        platform: plannedBackend.platform,
        shouldCancel: () => _cancelRequested,
        onResult: (result, completed, total) {
          if (!_isCurrent(generation) ||
              state.phase != FileOperationWorkflowPhase.executing) {
            return;
          }
          state = state.copyWith(
            reportedResults: [...state.reportedResults, result],
            completed: completed,
            total: total,
          );
        },
      );
      if (!_isCurrent(generation)) return;

      _executionBackend = plannedBackend;
      _currentExecution = execution;
      final cancelled = execution.results.any(
        (result) =>
            result.status == FileOperationStatus.cancelled ||
            result.issues.any(
              (issue) => issue.status == FileOperationStatus.cancelled,
            ),
      );
      final needsAttention = execution.results.any(
        (result) =>
            result.status != FileOperationStatus.copied &&
            result.status != FileOperationStatus.moved,
      );
      state = state.copyWith(
        phase: cancelled
            ? FileOperationWorkflowPhase.cancelled
            : FileOperationWorkflowPhase.completed,
        execution: execution,
        reportedResults: execution.results,
        completed: execution.results.length,
        total: plan.operations.length,
        message: cancelled
            ? 'Stopped safely. Review completed and cancelled files below.'
            : needsAttention
            ? 'Some file changes need attention. Review each result below.'
            : 'File changes completed.',
      );
    } on Object {
      if (!_isCurrent(generation)) return;
      _executionBackend = null;
      _currentExecution = null;
      state = state.copyWith(
        phase: FileOperationWorkflowPhase.error,
        message:
            'File changes could not be completed. Review before trying again.',
      );
    }
  }

  Future<void> recoverTemporary(FileOperationResult result) async {
    final execution = _currentExecution;
    final backend = _executionBackend;
    if (execution == null ||
        backend == null ||
        !identical(state.execution, execution) ||
        state.cleanupOperationId != null ||
        !execution.results.any((candidate) => identical(candidate, result)) ||
        result.effects.temporary != FileOperationTemporaryState.mayRemain ||
        result.effects.temporaryArtifact == null) {
      return;
    }

    final currentBackend = ref.read(fileOperationBackendProvider);
    if (!backend.canExecute ||
        !currentBackend.canExecute ||
        !identical(backend.platform, currentBackend.platform)) {
      state = state.copyWith(message: currentBackend.unavailableMessage);
      return;
    }

    final generation = _generation;
    state = state.copyWith(
      cleanupOperationId: result.operation.id,
      message: 'Retrying safe temporary cleanup…',
    );
    try {
      final recovered = await recoverTemporaryArtifact(
        result,
        platform: backend.platform,
      );
      if (!_isCurrent(generation) ||
          !identical(_currentExecution, execution) ||
          !identical(state.execution, execution)) {
        return;
      }
      final updatedResults = [
        for (final candidate in execution.results)
          if (identical(candidate, result)) recovered else candidate,
      ];
      final updatedExecution = FileOperationExecution(updatedResults);
      _currentExecution = updatedExecution;
      state = state.copyWith(
        execution: updatedExecution,
        reportedResults: updatedExecution.results,
        cleanupOperationId: null,
        message:
            recovered.effects.temporary == FileOperationTemporaryState.cleaned
            ? 'Temporary cleanup completed.'
            : 'Temporary cleanup still needs attention. Review the guidance below.',
      );
    } on Object {
      if (!_isCurrent(generation) ||
          !identical(_currentExecution, execution) ||
          !identical(state.execution, execution)) {
        return;
      }
      state = state.copyWith(
        cleanupOperationId: null,
        message:
            'Temporary cleanup could not be completed. Review the guidance below.',
      );
    }
  }

  void cancel() {
    if (state.phase == FileOperationWorkflowPhase.planning ||
        state.phase == FileOperationWorkflowPhase.preview) {
      discard();
    } else if (state.phase == FileOperationWorkflowPhase.executing) {
      if (_cancelRequested) return;
      _cancelRequested = true;
      state = state.copyWith(
        message: 'Stopping safely after the current file…',
      );
    }
  }

  void discard() {
    if (state.phase == FileOperationWorkflowPhase.executing) {
      cancel();
      return;
    }
    if (state.cleanupOperationId != null) return;
    _generation++;
    _cancelRequested = true;
    _plannedBackend = null;
    _executionBackend = null;
    _currentExecution = null;
    state = FileOperationWorkflowState();
  }

  bool _isCurrent(int generation) {
    return ref.mounted && generation == _generation;
  }
}

final sortFileOperationWorkflowProvider =
    NotifierProvider<
      FileOperationWorkflowController,
      FileOperationWorkflowState
    >(FileOperationWorkflowController.new);

final exportFileOperationWorkflowProvider =
    NotifierProvider<
      FileOperationWorkflowController,
      FileOperationWorkflowState
    >(FileOperationWorkflowController.new);
