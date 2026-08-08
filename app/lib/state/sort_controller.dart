import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/file_operations.dart';
import '../core/models.dart';
import '../core/sorter.dart';
import '../services/file_pick_service.dart';
import '../services/prefs_service.dart';
import 'file_operation_workflow.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum SortPhase { idle, sorting, done, error, empty, cancelled }

class SortUiState {
  const SortUiState({
    this.phase = SortPhase.idle,
    this.inputPath,
    this.outputPath,
    this.progress,
    this.result,
    this.message,
  });

  final SortPhase phase;
  final String? inputPath;
  final String? outputPath;
  final SortProgress? progress;
  final SortResult? result;
  final String? message;

  SortUiState copyWith({
    SortPhase? phase,
    Object? inputPath = _sentinel,
    Object? outputPath = _sentinel,
    Object? progress = _sentinel,
    Object? result = _sentinel,
    Object? message = _sentinel,
  }) {
    return SortUiState(
      phase: phase ?? this.phase,
      inputPath: inputPath == _sentinel ? this.inputPath : inputPath as String?,
      outputPath: outputPath == _sentinel
          ? this.outputPath
          : outputPath as String?,
      progress: progress == _sentinel
          ? this.progress
          : progress as SortProgress?,
      result: result == _sentinel ? this.result : result as SortResult?,
      message: message == _sentinel ? this.message : message as String?,
    );
  }

  static const _sentinel = Object();
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class SortController extends Notifier<SortUiState> {
  int _selectionGeneration = 0;

  @override
  SortUiState build() {
    // Prefill inputPath from prefs if the directory still exists.
    final prefs = ref.read(prefsServiceProvider);
    final saved = prefs.lastSortInputIfExists;
    return SortUiState(inputPath: saved);
  }

  /// Sets the input folder directly (bypasses file picker) and persists it.
  Future<void> setInput(String path) async {
    if (!_selectionCanChange) return;
    final selectionGeneration = ++_selectionGeneration;
    await _applyInput(path, selectionGeneration: selectionGeneration);
  }

  Future<void> _applyInput(
    String path, {
    required int selectionGeneration,
  }) async {
    if (!_selectionCanChange || selectionGeneration != _selectionGeneration) {
      return;
    }
    ref.read(sortFileOperationWorkflowProvider.notifier).discard();
    state = state.copyWith(
      inputPath: path,
      outputPath: null,
      result: null,
      message: null,
      phase: SortPhase.idle,
    );
    try {
      await ref.read(prefsServiceProvider).setLastSortInput(path);
    } catch (_) {
      // Prefs failure is non-fatal.
    }
  }

  /// Cancels an in-progress sort.
  void cancel() {
    ref.read(sortFileOperationWorkflowProvider.notifier).cancel();
  }

  Future<void> pickInput() async {
    if (!_selectionCanChange) return;
    final selectionGeneration = ++_selectionGeneration;
    final result = await ref
        .read(filePickServiceProvider)
        .pickDirectory(title: 'Choose photo folder');
    if (!_selectionCanChange || selectionGeneration != _selectionGeneration) {
      return;
    }
    if (result.warning != null) {
      state = state.copyWith(phase: SortPhase.error, message: result.warning);
      return;
    }
    if (result.path != null) {
      await _applyInput(result.path!, selectionGeneration: selectionGeneration);
    }
  }

  Future<void> pickOutput() async {
    if (!_selectionCanChange) return;
    final selectionGeneration = ++_selectionGeneration;
    final result = await ref
        .read(filePickServiceProvider)
        .pickDirectory(title: 'Choose output folder');
    if (!_selectionCanChange || selectionGeneration != _selectionGeneration) {
      return;
    }
    if (result.warning != null) {
      state = state.copyWith(phase: SortPhase.error, message: result.warning);
      return;
    }
    if (result.path != null) {
      ref.read(sortFileOperationWorkflowProvider.notifier).discard();
      state = state.copyWith(outputPath: result.path);
    }
  }

  Future<void> prepareSort() async {
    if (!_selectionCanChange) return;
    _selectionGeneration++;
    final inputPath = state.inputPath;
    if (inputPath == null) {
      state = state.copyWith(
        phase: SortPhase.error,
        message: 'Please choose an input folder first.',
      );
      return;
    }

    final outputPath = state.outputPath ?? inputPath;
    state = state.copyWith(
      phase: SortPhase.idle,
      progress: null,
      result: null,
      message: null,
    );
    await ref
        .read(sortFileOperationWorkflowProvider.notifier)
        .prepare(
          (platform) => planSortPhotos(
            input: DartFileProviderSelection.fromPath(inputPath),
            output: DartFileProviderSelection.fromPath(outputPath),
            platform: platform,
          ),
        );
  }

  /// Compatibility entry point while callers migrate to the preview wording.
  Future<void> start() => prepareSort();

  bool get _selectionCanChange {
    final workflow = ref.read(sortFileOperationWorkflowProvider);
    return !workflow.isActive;
  }
}

final sortControllerProvider = NotifierProvider<SortController, SortUiState>(
  SortController.new,
);
