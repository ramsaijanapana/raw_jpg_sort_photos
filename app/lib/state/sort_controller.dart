import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/folder_ref.dart';
import '../core/models.dart';
import '../core/sorter.dart';
import '../core/storage/io_storage_gateway.dart';
import '../core/storage/saf_storage_gateway.dart';
import '../core/storage/storage_gateway.dart';
import '../services/file_pick_service.dart';
import '../services/prefs_service.dart';
import '../services/saf/saf_channel.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

enum SortPhase { idle, sorting, done, error, empty, cancelled }

class SortUiState {
  const SortUiState({
    this.phase = SortPhase.idle,
    this.inputFolder,
    this.outputFolder,
    this.progress,
    this.result,
    this.message,
  });

  final SortPhase phase;
  final FolderRef? inputFolder;
  final FolderRef? outputFolder;
  final SortProgress? progress;
  final SortResult? result;
  final String? message;

  /// Local path only. Never a `content://` tree URI.
  String? get inputPath =>
      inputFolder is LocalFolder ? (inputFolder as LocalFolder).path : null;

  /// Local path only. Never a `content://` tree URI.
  String? get outputPath =>
      outputFolder is LocalFolder ? (outputFolder as LocalFolder).path : null;

  SortUiState copyWith({
    SortPhase? phase,
    Object? inputFolder = _sentinel,
    Object? outputFolder = _sentinel,
    Object? progress = _sentinel,
    Object? result = _sentinel,
    Object? message = _sentinel,
  }) {
    return SortUiState(
      phase: phase ?? this.phase,
      inputFolder: inputFolder == _sentinel
          ? this.inputFolder
          : inputFolder as FolderRef?,
      outputFolder: outputFolder == _sentinel
          ? this.outputFolder
          : outputFolder as FolderRef?,
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
  SortController({SafChannel? safChannel}) : _saf = safChannel ?? SafChannel();

  bool _cancelRequested = false;
  StorageGateway _gateway = IoStorageGateway();
  final SafChannel _saf;

  StorageGateway get storageGateway => _gateway;

  StorageGateway _gatewayFor(FolderRef folder) =>
      folder is SafTree ? SafStorageGateway(_saf) : IoStorageGateway();

  @override
  SortUiState build() {
    _gateway = IoStorageGateway();
    final prefs = ref.read(prefsServiceProvider);
    final saved = prefs.lastSortInputIfExists;
    if (saved != null) {
      return SortUiState(inputFolder: LocalFolder(saved));
    }
    if (FilePickService.looksLikeContentTreeUri(prefs.lastSortInput)) {
      Future<void>(() => restoreLastInput());
    }
    return const SortUiState();
  }

  /// Sets the input folder directly (bypasses file picker) and persists it.
  Future<void> setInput(String path) async {
    _gateway = IoStorageGateway();
    state = state.copyWith(
      inputFolder: LocalFolder(path),
      outputFolder: null,
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

  Future<void> restoreLastInput() async {
    final prefs = ref.read(prefsServiceProvider);
    final raw = prefs.lastSortInput;
    if (raw == null || raw.isEmpty) return;
    final local = prefs.lastSortInputIfExists;
    if (local != null) {
      _gateway = IoStorageGateway();
      state = state.copyWith(
        inputFolder: LocalFolder(local),
        phase: SortPhase.idle,
        message: null,
      );
      return;
    }

    final folder = await ref.read(filePickServiceProvider).restorePersistedFolder(
          raw,
          clearStale: prefs.clearLastSortInput,
        );
    if (folder == null) {
      _gateway = IoStorageGateway();
      state = state.copyWith(
        inputFolder: null,
        phase: SortPhase.error,
        message: directoryAccessWarning,
      );
      return;
    }
    _gateway = _gatewayFor(folder);
    state = state.copyWith(
      inputFolder: folder,
      phase: SortPhase.idle,
      message: null,
    );
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
    if (result.folder != null) {
      _applyPickedInput(result.folder!);
      try {
        await ref
            .read(prefsServiceProvider)
            .setLastSortInput(_persistString(result.folder!));
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
    if (result.folder != null) {
      state = state.copyWith(outputFolder: result.folder);
    }
  }

  Future<void> start() async {
    final inputFolder = state.inputFolder;
    if (inputFolder == null) {
      state = state.copyWith(
        phase: SortPhase.error,
        message: 'Please choose an input folder first.',
      );
      return;
    }

    final outputFolder = state.outputFolder ?? inputFolder;
    if (!_sameFolderKind(inputFolder, outputFolder)) {
      state = state.copyWith(
        phase: SortPhase.error,
        message: 'Input and output folders must use the same storage type.',
      );
      return;
    }

    _gateway = _gatewayFor(inputFolder);
    _cancelRequested = false;
    state = state.copyWith(
      phase: SortPhase.sorting,
      progress: null,
      result: null,
      message: null,
    );

    try {
      final result = await sortPhotos(
        input: inputFolder,
        output: outputFolder,
        gateway: _gateway,
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

  void _applyPickedInput(FolderRef folder) {
    _gateway = _gatewayFor(folder);
    state = state.copyWith(
      inputFolder: folder,
      outputFolder: null,
      result: null,
      message: null,
      phase: SortPhase.idle,
    );
  }
}

String _persistString(FolderRef folder) {
  if (folder is LocalFolder) return folder.path;
  return (folder as SafTree).treeUri;
}

bool _sameFolderKind(FolderRef a, FolderRef b) =>
    (a is LocalFolder && b is LocalFolder) || (a is SafTree && b is SafTree);

final sortControllerProvider =
    NotifierProvider<SortController, SortUiState>(SortController.new);
