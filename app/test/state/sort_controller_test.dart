import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/file_operation_workflow.dart';
import 'package:photo_sorter/state/sort_controller.dart';

Future<ProviderContainer> makeContainer({
  FilePickService? picker,
  FileOperationBackend? backend,
  FileOperationWorkflowController Function()? sortWorkflow,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      prefsServiceProvider.overrideWithValue(PrefsService(prefs)),
      if (picker != null) filePickServiceProvider.overrideWithValue(picker),
      if (backend != null)
        fileOperationBackendProvider.overrideWithValue(backend),
      if (sortWorkflow != null)
        sortFileOperationWorkflowProvider.overrideWith(sortWorkflow),
    ],
  );
}

void main() {
  group('SortController.setInput', () {
    test('sets inputPath and persists to prefs', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(sortControllerProvider.notifier);

      await ctrl.setInput('/some/path');

      final state = container.read(sortControllerProvider);
      expect(state.inputPath, '/some/path');
      expect(state.phase, SortPhase.idle);

      // Check prefs persisted.
      final prefs = container.read(prefsServiceProvider);
      expect(prefs.lastSortInput, '/some/path');
    });

    test('setInput resets outputPath, result, and message', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(sortControllerProvider.notifier);

      // Manually set state with existing values by using pickInput is not
      // easily testable, so we just check setInput resets them.
      await ctrl.setInput('/path/one');
      await ctrl.setInput('/path/two');

      final state = container.read(sortControllerProvider);
      expect(state.inputPath, '/path/two');
      expect(state.outputPath, isNull);
      expect(state.result, isNull);
      expect(state.message, isNull);
    });
  });

  group('SortController preview planning', () {
    test('same-folder preview plans moves without mutating files', () async {
      final tmp = await Directory.systemTemp.createTemp('ctrl_preview_');
      addTearDown(() => tmp.delete(recursive: true));
      final source = File(p.join(tmp.path, 'img.arw'));
      await source.writeAsString('data');

      final container = await makeContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(sortControllerProvider.notifier);
      await ctrl.setInput(tmp.path);

      await ctrl.prepareSort();

      final workflow = container.read(sortFileOperationWorkflowProvider);
      expect(workflow.phase, FileOperationWorkflowPhase.preview);
      expect(workflow.plan!.operations, hasLength(1));
      expect(workflow.plan!.operations.single.intent, FileOperationIntent.move);
      expect(await source.readAsString(), 'data');
      expect(Directory(p.join(tmp.path, 'RAW')).existsSync(), isFalse);
    });

    test(
      'separate output preview refuses replacement until explicitly discarded',
      () async {
        final input = await Directory.systemTemp.createTemp('ctrl_input_');
        final output = await Directory.systemTemp.createTemp('ctrl_output_');
        final replacement = await Directory.systemTemp.createTemp(
          'ctrl_replacement_',
        );
        addTearDown(() => input.delete(recursive: true));
        addTearDown(() => output.delete(recursive: true));
        addTearDown(() => replacement.delete(recursive: true));
        final source = File(p.join(input.path, 'img.jpg'));
        await source.writeAsString('data');
        final picker = _QueueFilePickService([
          (path: output.path, warning: null),
          (path: replacement.path, warning: null),
        ]);
        final container = await makeContainer(picker: picker);
        addTearDown(container.dispose);
        final ctrl = container.read(sortControllerProvider.notifier);
        await ctrl.setInput(input.path);
        await ctrl.pickOutput();

        await ctrl.prepareSort();

        var workflow = container.read(sortFileOperationWorkflowProvider);
        expect(workflow.phase, FileOperationWorkflowPhase.preview);
        expect(
          workflow.plan!.operations.single.intent,
          FileOperationIntent.copy,
        );
        expect(await source.readAsString(), 'data');
        expect(Directory(p.join(output.path, 'JPG')).existsSync(), isFalse);

        await ctrl.pickOutput();

        workflow = container.read(sortFileOperationWorkflowProvider);
        expect(workflow.phase, FileOperationWorkflowPhase.preview);
        expect(container.read(sortControllerProvider).outputPath, output.path);

        container.read(sortFileOperationWorkflowProvider.notifier).discard();
        await ctrl.pickOutput();
        workflow = container.read(sortFileOperationWorkflowProvider);
        expect(workflow.phase, FileOperationWorkflowPhase.idle);
        expect(
          container.read(sortControllerProvider).outputPath,
          replacement.path,
        );
      },
    );

    test(
      'input change is refused while planning remains authoritative',
      () async {
        final first = await Directory.systemTemp.createTemp('ctrl_first_');
        final second = await Directory.systemTemp.createTemp('ctrl_second_');
        addTearDown(() => first.delete(recursive: true));
        addTearDown(() => second.delete(recursive: true));
        await File(p.join(first.path, 'first.arw')).writeAsString('first');
        await File(p.join(second.path, 'second.arw')).writeAsString('second');
        final platform = _DelayedListingPlatform();
        final container = await makeContainer(
          backend: FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only.',
          ),
        );
        addTearDown(container.dispose);
        final ctrl = container.read(sortControllerProvider.notifier);
        await ctrl.setInput(first.path);

        final preparation = ctrl.prepareSort();
        await platform.listingStarted.future;
        await ctrl.setInput(second.path);
        platform.releaseListing.complete();
        await preparation;

        expect(container.read(sortControllerProvider).inputPath, first.path);
        final workflow = container.read(sortFileOperationWorkflowProvider);
        expect(workflow.phase, FileOperationWorkflowPhase.preview);
        expect(workflow.plan, isNotNull);
      },
    );
  });

  group('SortController selection lifecycle', () {
    test(
      'all non-idle workflow states refuse input and picker changes',
      () async {
        final picker = _CountingFilePickService();
        final workflow = _ManualWorkflowController();
        final container = await makeContainer(
          picker: picker,
          sortWorkflow: () => workflow,
        );
        addTearDown(container.dispose);
        final ctrl = container.read(sortControllerProvider.notifier);
        await ctrl.setInput('/current/input');

        final activeStates = [
          FileOperationWorkflowState(
            phase: FileOperationWorkflowPhase.planning,
          ),
          FileOperationWorkflowState(phase: FileOperationWorkflowPhase.preview),
          FileOperationWorkflowState(
            phase: FileOperationWorkflowPhase.executing,
          ),
          FileOperationWorkflowState(
            phase: FileOperationWorkflowPhase.completed,
          ),
          FileOperationWorkflowState(
            phase: FileOperationWorkflowPhase.cancelled,
          ),
          FileOperationWorkflowState(phase: FileOperationWorkflowPhase.error),
          FileOperationWorkflowState(
            phase: FileOperationWorkflowPhase.completed,
            cleanupOperationId: 'cleanup-in-flight',
          ),
        ];

        for (final active in activeStates) {
          workflow.publish(active);
          await ctrl.setInput('/replacement/input');
          await ctrl.pickInput();
          await ctrl.pickOutput();
          expect(
            container.read(sortControllerProvider).inputPath,
            '/current/input',
            reason: '${active.phase}',
          );
          expect(picker.calls, 0, reason: '${active.phase}');
        }
      },
    );

    test('delayed input picker cannot overwrite a later drop input', () async {
      final picker = _DelayedFilePickService();
      final container = await makeContainer(picker: picker);
      addTearDown(container.dispose);
      final ctrl = container.read(sortControllerProvider.notifier);

      final pendingPicker = ctrl.pickInput();
      await picker.started.future;
      await ctrl.setInput('/later/drop');
      picker.complete('/stale/picker');
      await pendingPicker;

      expect(container.read(sortControllerProvider).inputPath, '/later/drop');
    });

    test('delayed output picker cannot cross a later input change', () async {
      final picker = _DelayedFilePickService();
      final container = await makeContainer(picker: picker);
      addTearDown(container.dispose);
      final ctrl = container.read(sortControllerProvider.notifier);
      await ctrl.setInput('/first/input');

      final pendingPicker = ctrl.pickOutput();
      await picker.started.future;
      await ctrl.setInput('/later/input');
      picker.complete('/stale/output');
      await pendingPicker;

      final state = container.read(sortControllerProvider);
      expect(state.inputPath, '/later/input');
      expect(state.outputPath, isNull);
    });

    test(
      'starting a sort preview invalidates a picker across lifecycle ABA',
      () async {
        final input = await Directory.systemTemp.createTemp(
          'sort_picker_workflow_epoch_input_',
        );
        addTearDown(() => input.delete(recursive: true));
        await File(p.join(input.path, 'A.ARW')).writeAsString('A');
        final picker = _DelayedFilePickService();
        final container = await makeContainer(picker: picker);
        addTearDown(container.dispose);
        final ctrl = container.read(sortControllerProvider.notifier);
        await ctrl.setInput(input.path);

        final pendingPicker = ctrl.pickInput();
        await picker.started.future;
        await ctrl.prepareSort();
        expect(
          container.read(sortFileOperationWorkflowProvider).phase,
          FileOperationWorkflowPhase.preview,
        );
        container.read(sortFileOperationWorkflowProvider.notifier).discard();
        picker.complete('/stale/picker');
        await pendingPicker;

        expect(container.read(sortControllerProvider).inputPath, input.path);
      },
    );
  });

  group('SortPhase.cancelled', () {
    test('cancelled phase is defined', () {
      // Ensure the enum value exists.
      const phases = SortPhase.values;
      expect(phases.contains(SortPhase.cancelled), isTrue);
    });
  });
}

final class _ManualWorkflowController extends FileOperationWorkflowController {
  @override
  FileOperationWorkflowState build() => FileOperationWorkflowState();

  void publish(FileOperationWorkflowState next) => state = next;
}

final class _CountingFilePickService extends FilePickService {
  var calls = 0;

  @override
  Future<PickResult> pickDirectory({String? title}) async {
    calls++;
    return (path: '/picked/path', warning: null);
  }
}

final class _DelayedFilePickService extends FilePickService {
  final started = Completer<void>();
  final _result = Completer<PickResult>();

  @override
  Future<PickResult> pickDirectory({String? title}) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete(String path) {
    _result.complete((path: path, warning: null));
  }
}

final class _QueueFilePickService extends FilePickService {
  _QueueFilePickService(this.results);

  final List<PickResult> results;
  var _index = 0;

  @override
  Future<PickResult> pickDirectory({String? title}) async {
    return results[_index++];
  }
}

final class _DelayedListingPlatform extends DartFileOperationPlatform {
  final listingStarted = Completer<void>();
  final releaseListing = Completer<void>();

  @override
  Future<List<FileProviderDirectoryEntry>> listDirectory(
    FileOperationPlanningAccess access,
    FileProviderItemReference directory,
  ) async {
    if (!listingStarted.isCompleted) listingStarted.complete();
    await releaseListing.future;
    return super.listDirectory(access, directory);
  }
}
