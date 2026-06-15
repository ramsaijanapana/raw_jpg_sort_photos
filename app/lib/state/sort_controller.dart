import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/sorter.dart';
import '../services/file_pick_service.dart';
import '../services/prefs_service.dart';

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
      inputPath:
          inputPath == _sentinel ? this.inputPath : inputPath as String?,
      outputPath:
          outputPath == _sentinel ? this.outputPath : outputPath as String?,
      progress:
          progress == _sentinel ? this.progress : progress as SortProgress?,
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
  bool _cancelRequested = false;

  @override
  SortUiState build() {
    // Prefill inputPath from prefs if the directory still exists.
    final prefs = ref.read(prefsServiceProvider);
    final saved = prefs.lastSortInputIfExists;
    return SortUiState(inputPath: saved);
  }

  /// Sets the input folder directly (bypasses file picker) and persists it.
  Future<void> setInput(String path) async {
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
    _cancelRequested = true;
  }

  Future<void> pickInput() async {
    final result = await ref
        .read(filePickServiceProvider)
        .pickDirectory(title: 'Choose photo folder');
    if (result.warning != null) {
      state = state.copyWith(
        phase: SortPhase.error,
        message: result.warning,
      );
      return;
    }
    if (result.path != null) {
      state = state.copyWith(
        inputPath: result.path,
        // Reset output and result when a new input is chosen.
        outputPath: null,
        result: null,
        message: null,
        phase: SortPhase.idle,
      );
      // Persist for next session.
      try {
        await ref.read(prefsServiceProvider).setLastSortInput(result.path!);
      } catch (_) {
        // Prefs failure is non-fatal.
      }
    }
  }

  Future<void> pickOutput() async {
    final result = await ref
        .read(filePickServiceProvider)
        .pickDirectory(title: 'Choose output folder');
    if (result.warning != null) {
      state = state.copyWith(
        phase: SortPhase.error,
        message: result.warning,
      );
      return;
    }
    if (result.path != null) {
      state = state.copyWith(outputPath: result.path);
    }
  }

  Future<void> start() async {
    final inputPath = state.inputPath;
    if (inputPath == null) {
      state = state.copyWith(
        phase: SortPhase.error,
        message: 'Please choose an input folder first.',
      );
      return;
    }

    final inputDir = Directory(inputPath);
    final outputDir = Directory(state.outputPath ?? inputPath);

    _cancelRequested = false;
    state = state.copyWith(
      phase: SortPhase.sorting,
      progress: null,
      result: null,
      message: null,
    );

    try {
      final result = await sortPhotos(
        input: inputDir,
        output: outputDir,
        onProgress: (p) {
          state = state.copyWith(phase: SortPhase.sorting, progress: p);
        },
        shouldCancel: () => _cancelRequested,
      );

      if (result.cancelled) {
        final total = (result.rawCount + result.jpgCount + result.skipped);
        state = state.copyWith(
          phase: SortPhase.cancelled,
          result: result,
          progress: null,
          message: 'Stopped after $total of ${state.progress?.total ?? total} files — files already sorted stay in place.',
        );
      } else if (result.rawCount == 0 && result.jpgCount == 0) {
        state = state.copyWith(
          phase: SortPhase.empty,
          result: result,
          progress: null,
          message:
              'No RAW or JPG files found in the selected folder.',
        );
      } else {
        state = state.copyWith(
          phase: SortPhase.done,
          result: result,
          progress: null,
        );
      }
    } catch (e) {
      state = state.copyWith(
        phase: SortPhase.error,
        progress: null,
        message: 'Sort failed: $e',
      );
    }
  }
}

final sortControllerProvider =
    NotifierProvider<SortController, SortUiState>(SortController.new);
