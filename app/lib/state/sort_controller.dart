import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/sorter.dart';
import '../services/file_pick_service.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum SortPhase { idle, sorting, done, error, empty }

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
  final _filePick = FilePickService();

  @override
  SortUiState build() => const SortUiState();

  Future<void> pickInput() async {
    final result = await _filePick.pickDirectory(title: 'Choose photo folder');
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
    }
  }

  Future<void> pickOutput() async {
    final result = await _filePick.pickDirectory(title: 'Choose output folder');
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
      );

      if (result.rawCount == 0 && result.jpgCount == 0) {
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
