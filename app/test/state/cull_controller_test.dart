import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';
import 'package:photo_sorter/state/file_operation_workflow.dart';

/// Returns a [ProviderContainer] with a no-op [PrefsService] override.
Future<ProviderContainer> makeContainer({
  FileOperationBackend? backend,
  FileOperationWorkflowController Function()? exportWorkflow,
  CullController Function()? cullController,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      prefsServiceProvider.overrideWithValue(PrefsService(prefs)),
      if (backend != null)
        fileOperationBackendProvider.overrideWithValue(backend),
      if (exportWorkflow != null)
        exportFileOperationWorkflowProvider.overrideWith(exportWorkflow),
      if (cullController != null)
        cullControllerProvider.overrideWith(cullController),
    ],
  );
  return container;
}

void main() {
  group('goto with empty pairs (P0-4 regression)', () {
    test('End / Home / nav do not throw when no folder is open', () async {
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);

      // No folder open → pairs is empty. These must not throw (clamp(0, -1)).
      expect(() => ctrl.goto(0), returnsNormally); // Home
      expect(() => ctrl.goto(-1), returnsNormally); // End-ish (length - 1)
      expect(() => ctrl.goto(1000), returnsNormally);
      expect(() => ctrl.nav(1), returnsNormally);
      expect(() => ctrl.nav(-1), returnsNormally);

      expect(container.read(cullControllerProvider).index, 0);
    });
  });

  group('rapid keep() bursts (P0-1 auto-advance race)', () {
    test(
      'three keep() calls within 120ms fire only one auto-advance',
      () async {
        // Open the folder with real async I/O first, then test timer behaviour.
        final tmp = Directory.systemTemp.createTempSync('rapid_keep_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        for (final name in [
          'IMG_001.ARW',
          'IMG_002.ARW',
          'IMG_003.ARW',
          'IMG_004.ARW',
        ]) {
          File(p.join(tmp.path, name)).writeAsBytesSync([0, 1, 2, 3]);
        }

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);

        // Complete the real async open before entering fakeAsync.
        await ctrl.openFolder(tmp.path);
        expect(container.read(cullControllerProvider).pairs.length, 4);
        expect(container.read(cullControllerProvider).index, 0);

        // Fire three keep() in quick succession (each cancels the prior
        // timer). On a fast machine all three flag the same pair; on a slow
        // CI runner an earlier timer may legitimately fire in between and
        // advance first. Either way the race-free invariant below must hold.
        ctrl.keep();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ctrl.keep();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ctrl.keep();

        // Wait until the index stabilizes (unchanged for 300ms, max 3s) —
        // fixed sleeps are flaky on loaded CI runners where the session-file
        // write delays the timer scheduling.
        var last = container.read(cullControllerProvider).index;
        var stableMs = 0;
        var waitedMs = 0;
        while (stableMs < 300 && waitedMs < 3000) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          waitedMs += 50;
          final now = container.read(cullControllerProvider).index;
          if (now == last) {
            stableMs += 50;
          } else {
            last = now;
            stableMs = 0;
          }
        }

        // The race this guards against is a DOUBLE advance (overlapping timers
        // skipping past an undecided photo). Invariant: the index landed on
        // the first undecided pair — every pair before it is kept, none were
        // skipped over.
        final state = container.read(cullControllerProvider);
        expect(
          state.index,
          state.keptCount,
          reason: 'index must sit on the first undecided pair',
        );
        expect(state.keptCount, greaterThanOrEqualTo(1));
        expect(state.keptCount, lessThanOrEqualTo(3));
        for (var i = 0; i < state.index; i++) {
          expect(
            state.flags[state.pairs[i].stem],
            CullFlag.keep,
            reason: 'no pair before the index may be left undecided',
          );
        }
        expect(
          state.flags[state.pairs[state.index].stem] ?? CullFlag.undecided,
          CullFlag.undecided,
        );
      },
    );
  });

  group('openFolder concurrency (P0-5 generation guard)', () {
    test('the second openFolder wins; final state is folder B', () async {
      final dirA = await Directory.systemTemp.createTemp('open_A_');
      final dirB = await Directory.systemTemp.createTemp('open_B_');
      addTearDown(() async {
        await dirA.delete(recursive: true);
        await dirB.delete(recursive: true);
      });

      // Folder A: two stems. Folder B: three different stems + a flag file.
      for (final n in ['A_001.ARW', 'A_002.ARW']) {
        await File(p.join(dirA.path, n)).writeAsBytes([0, 1]);
      }
      for (final n in ['B_001.ARW', 'B_002.ARW', 'B_003.ARW']) {
        await File(p.join(dirB.path, n)).writeAsBytes([2, 3]);
      }
      await File(
        p.join(dirB.path, 'cull_session.json'),
      ).writeAsString('{"B_001":"keep"}');

      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);

      // Start A then immediately B, then await both.
      final fa = ctrl.openFolder(dirA.path);
      final fb = ctrl.openFolder(dirB.path);
      await Future.wait([fa, fb]);

      final state = container.read(cullControllerProvider);
      // Final committed state must be folder B's pairs and flags.
      expect(state.pairs.map((e) => e.stem).toList()..sort(), [
        'B_001',
        'B_002',
        'B_003',
      ]);
      expect(state.flags['B_001'], CullFlag.keep);
      expect(state.dir!.path, dirB.path);
    });
  });

  // -------------------------------------------------------------------------
  // Undo tests (Wave 1 - spec §1.2)
  // -------------------------------------------------------------------------

  group('undo stack', () {
    test(
      'flag K, X, K on 3 fake pairs → undo() restores in reverse order',
      () async {
        final tmp = Directory.systemTemp.createTempSync('undo_test_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        for (final name in ['P001.ARW', 'P002.ARW', 'P003.ARW']) {
          File(p.join(tmp.path, name)).writeAsBytesSync([0, 1, 2, 3]);
        }

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);

        await ctrl.openFolder(tmp.path);
        // Navigate: flag P001 = keep
        ctrl.goto(0);
        await ctrl.keep();
        // Navigate: flag P002 = skip
        ctrl.goto(1);
        await ctrl.skip();
        // Navigate: flag P003 = keep
        ctrl.goto(2);
        await ctrl.keep();

        var state = container.read(cullControllerProvider);
        expect(state.flags['P001'], CullFlag.keep);
        expect(state.flags['P002'], CullFlag.skip);
        expect(state.flags['P003'], CullFlag.keep);
        expect(state.index, 2);

        // Undo P003 keep → undecided, index returns to 2
        await ctrl.undo();
        state = container.read(cullControllerProvider);
        expect(state.flags['P003'], isNull); // undecided = not in map
        expect(state.index, 2);

        // Undo P002 skip → undecided, index returns to 1
        await ctrl.undo();
        state = container.read(cullControllerProvider);
        expect(state.flags['P002'], isNull);
        expect(state.index, 1);

        // Undo P001 keep → undecided, index returns to 0
        await ctrl.undo();
        state = container.read(cullControllerProvider);
        expect(state.flags['P001'], isNull);
        expect(state.index, 0);

        // Undo on empty stack is no-op
        await ctrl.undo();
        state = container.read(cullControllerProvider);
        expect(state.keptCount, 0);
        expect(state.skipCount, 0);
      },
    );

    test('undo after openFolder clears the stack', () async {
      final tmp1 = Directory.systemTemp.createTempSync('undo_clear1_');
      final tmp2 = Directory.systemTemp.createTempSync('undo_clear2_');
      addTearDown(() {
        tmp1.deleteSync(recursive: true);
        tmp2.deleteSync(recursive: true);
      });
      for (final name in ['A001.ARW', 'A002.ARW']) {
        File(p.join(tmp1.path, name)).writeAsBytesSync([0]);
        File(p.join(tmp2.path, name)).writeAsBytesSync([0]);
      }

      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);

      await ctrl.openFolder(tmp1.path);
      ctrl.goto(0);
      await ctrl.keep();
      expect(container.read(cullControllerProvider).keptCount, 1);

      // Re-open a DIFFERENT folder clears undo stack.
      await ctrl.openFolder(tmp2.path);
      await ctrl.undo(); // should be no-op (stack was cleared)
      final state = container.read(cullControllerProvider);
      // Folder 2 has no flags → kept count should be 0.
      expect(state.keptCount, 0);
    });

    test('session file updated after undo', () async {
      final tmp = Directory.systemTemp.createTempSync('undo_session_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      for (final name in ['Q001.ARW']) {
        File(p.join(tmp.path, name)).writeAsBytesSync([0]);
      }

      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);

      await ctrl.openFolder(tmp.path);
      ctrl.goto(0);
      await ctrl.keep();

      var sessionFile = File(p.join(tmp.path, 'cull_session.json'));
      expect(await sessionFile.readAsString(), contains('"Q001":"keep"'));

      await ctrl.undo();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final content = await sessionFile.readAsString();
      // After undo, Q001 is undecided so should not appear in the session.
      expect(content, isNot(contains('"Q001"')));
    });
  });

  group('export preview snapshot', () {
    test(
      'planning locks decisions and a later invocation snapshots fresh decisions',
      () async {
        final source = await Directory.systemTemp.createTemp('export_source_');
        final destination = await Directory.systemTemp.createTemp(
          'export_destination_',
        );
        addTearDown(() => source.delete(recursive: true));
        addTearDown(() => destination.delete(recursive: true));
        for (final name in ['A.ARW', 'A.JPG', 'B.ARW', 'B.JPG']) {
          await File(p.join(source.path, name)).writeAsString(name);
        }
        final platform = _DelayedResolvePlatform();
        final container = await makeContainer(
          backend: FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only.',
          ),
        );
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        await ctrl.openFolder(source.path);
        ctrl.goto(0);
        await ctrl.keep();
        ctrl.goto(1);
        await ctrl.skip();

        final firstPreparation = ctrl.prepareExport(
          destinationPath: destination.path,
          includeJpgs: true,
        );
        await platform.resolutionStarted.future;
        ctrl.goto(0);
        await ctrl.unflag();
        ctrl.goto(1);
        await ctrl.keep();
        var current = container.read(cullControllerProvider);
        expect(current.flags['A'], CullFlag.keep);
        expect(current.flags['B'], CullFlag.skip);
        platform.releaseResolution.complete();
        await firstPreparation;

        var workflow = container.read(exportFileOperationWorkflowProvider);
        expect(workflow.phase, FileOperationWorkflowPhase.preview);
        expect(
          workflow.plan!.operations
              .map((operation) => operation.source.itemName!.value)
              .toList(),
          ['A.ARW', 'A.JPG'],
        );
        expect(
          await File(p.join(source.path, 'A.ARW')).readAsString(),
          'A.ARW',
        );
        expect(
          Directory(p.join(destination.path, 'A.ARW')).existsSync(),
          isFalse,
        );

        container.read(exportFileOperationWorkflowProvider.notifier).discard();
        ctrl.goto(0);
        await ctrl.unflag();
        ctrl.goto(1);
        await ctrl.keep();
        await ctrl.prepareExport(
          destinationPath: destination.path,
          includeJpgs: false,
        );

        workflow = container.read(exportFileOperationWorkflowProvider);
        expect(workflow.phase, FileOperationWorkflowPhase.preview);
        expect(
          workflow.plan!.operations
              .map((operation) => operation.source.itemName!.value)
              .toList(),
          ['B.ARW'],
        );
      },
    );
  });

  group('export folder lifecycle authority', () {
    test(
      'decision mutations refuse every active export phase and cleanup',
      () async {
        final source = await Directory.systemTemp.createTemp(
          'export_flag_guard_source_',
        );
        addTearDown(() => source.delete(recursive: true));
        await File(p.join(source.path, 'A.ARW')).writeAsString('A');

        final workflow = _ManualWorkflowController();
        final container = await makeContainer(exportWorkflow: () => workflow);
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        container.read(exportFileOperationWorkflowProvider);
        await ctrl.openFolder(source.path);
        await ctrl.keep();

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
          final before = Map<String, CullFlag>.from(
            container.read(cullControllerProvider).flags,
          );
          await ctrl.keep();
          await ctrl.skip();
          await ctrl.unflag();
          await ctrl.undo();
          expect(
            container.read(cullControllerProvider).flags,
            before,
            reason: '${active.phase}',
          );
        }
      },
    );

    test('loading refuses flag mutations and old-session writes', () async {
      final source = await Directory.systemTemp.createTemp(
        'export_loading_flag_guard_source_',
      );
      addTearDown(() => source.delete(recursive: true));
      await File(p.join(source.path, 'A.ARW')).writeAsString('A');

      final inspectable = _InspectableCullController();
      final container = await makeContainer(cullController: () => inspectable);
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openFolder(source.path);
      await ctrl.keep();
      final session = File(p.join(source.path, 'cull_session.json'));
      final sessionBefore = await session.readAsString();
      final stateBefore = container.read(cullControllerProvider);
      inspectable.publish(stateBefore.copyWith(loading: true));

      await ctrl.keep();
      await ctrl.skip();
      await ctrl.unflag();
      await ctrl.undo();

      expect(container.read(cullControllerProvider).flags, stateBefore.flags);
      expect(await session.readAsString(), sessionBefore);
    });

    test('published export collections cannot be mutated by callers', () async {
      final source = await Directory.systemTemp.createTemp(
        'export_immutable_state_source_',
      );
      addTearDown(() => source.delete(recursive: true));
      await File(p.join(source.path, 'A.ARW')).writeAsString('A');

      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openFolder(source.path);

      final state = container.read(cullControllerProvider);
      expect(
        () => state.pairs.add(
          PhotoPair(stem: 'INJECTED', raw: File('/opaque/injected.arw')),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => state.flags['INJECTED'] = CullFlag.keep,
        throwsUnsupportedError,
      );
    });

    test('CullState snapshots caller-owned export collections', () {
      final pairs = <PhotoPair>[
        PhotoPair(stem: 'A', raw: File('/opaque/A.ARW')),
      ];
      final flags = <String, CullFlag>{'A': CullFlag.keep};
      final state = CullState(pairs: pairs, flags: flags);

      pairs.clear();
      flags.clear();

      expect(state.pairs, hasLength(1));
      expect(state.flags, {'A': CullFlag.keep});
      expect(() => state.pairs.clear(), throwsUnsupportedError);
      expect(() => state.flags.clear(), throwsUnsupportedError);
    });

    test(
      'a failed replacement open clears the old export selection with a safe error',
      () async {
        final current = await Directory.systemTemp.createTemp(
          'export_failed_open_current_',
        );
        addTearDown(() => current.delete(recursive: true));
        await File(p.join(current.path, 'OLD.ARW')).writeAsString('old');

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        await ctrl.openFolder(current.path);
        await ctrl.keep();

        final missing = p.join(current.parent.path, 'missing-photo-folder');
        await ctrl.openFolder(missing);

        final state = container.read(cullControllerProvider);
        expect(state.loading, isFalse);
        expect(state.dir, isNull);
        expect(state.pairs, isEmpty);
        expect(state.flags, isEmpty);
        expect(
          state.error,
          'Could not open that folder. Choose a folder and try again.',
        );
        expect(state.error, isNot(contains(missing)));
        expect(ctrl.captureExportSelectionRevision(), isNull);
      },
    );

    test('openFolder refuses every non-idle export workflow state', () async {
      final current = await Directory.systemTemp.createTemp(
        'export_guard_current_',
      );
      final replacement = await Directory.systemTemp.createTemp(
        'export_guard_replacement_',
      );
      addTearDown(() => current.delete(recursive: true));
      addTearDown(() => replacement.delete(recursive: true));
      await File(p.join(current.path, 'CURRENT.ARW')).writeAsString('current');
      await File(
        p.join(replacement.path, 'REPLACEMENT.ARW'),
      ).writeAsString('replacement');

      final workflow = _ManualWorkflowController();
      final container = await makeContainer(exportWorkflow: () => workflow);
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      container.read(exportFileOperationWorkflowProvider);
      await ctrl.openFolder(current.path);

      final activeStates = [
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.planning),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.preview),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.executing),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.completed),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.cancelled),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.error),
        FileOperationWorkflowState(
          phase: FileOperationWorkflowPhase.completed,
          cleanupOperationId: 'cleanup-in-flight',
        ),
      ];

      for (final active in activeStates) {
        workflow.publish(active);
        await ctrl.openFolder(replacement.path);
        final state = container.read(cullControllerProvider);
        expect(state.dir!.path, current.path, reason: '${active.phase}');
        expect(state.pairs.single.stem, 'CURRENT', reason: '${active.phase}');
      }
    });

    test(
      'loading blocks export planning so old pairs cannot cross into a new folder',
      () async {
        final current = await Directory.systemTemp.createTemp(
          'export_loading_current_',
        );
        final replacement = await Directory.systemTemp.createTemp(
          'export_loading_replacement_',
        );
        final destination = await Directory.systemTemp.createTemp(
          'export_loading_destination_',
        );
        addTearDown(() => current.delete(recursive: true));
        addTearDown(() => replacement.delete(recursive: true));
        addTearDown(() => destination.delete(recursive: true));
        await File(p.join(current.path, 'OLD.ARW')).writeAsString('old');
        await File(p.join(replacement.path, 'NEW.ARW')).writeAsString('new');

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        await ctrl.openFolder(current.path);
        await ctrl.keep();

        final opening = ctrl.openFolder(replacement.path);
        expect(container.read(cullControllerProvider).loading, isTrue);
        await ctrl.prepareExport(
          destinationPath: destination.path,
          includeJpgs: true,
        );
        await opening;

        final state = container.read(cullControllerProvider);
        expect(state.dir!.path, replacement.path);
        expect(state.pairs.single.stem, 'NEW');
        expect(
          container.read(exportFileOperationWorkflowProvider).phase,
          FileOperationWorkflowPhase.idle,
        );
      },
    );

    test('prepareExport refuses every non-idle workflow state', () async {
      final source = await Directory.systemTemp.createTemp(
        'export_prepare_guard_source_',
      );
      final destination = await Directory.systemTemp.createTemp(
        'export_prepare_guard_destination_',
      );
      addTearDown(() => source.delete(recursive: true));
      addTearDown(() => destination.delete(recursive: true));
      await File(p.join(source.path, 'KEPT.ARW')).writeAsString('kept');

      final workflow = _ManualWorkflowController();
      final container = await makeContainer(exportWorkflow: () => workflow);
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      container.read(exportFileOperationWorkflowProvider);
      await ctrl.openFolder(source.path);
      await ctrl.keep();

      final activeStates = [
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.planning),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.preview),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.executing),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.completed),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.cancelled),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.error),
        FileOperationWorkflowState(
          phase: FileOperationWorkflowPhase.completed,
          cleanupOperationId: 'cleanup-in-flight',
        ),
      ];

      for (final active in activeStates) {
        workflow.publish(active);
        await ctrl.prepareExport(
          destinationPath: destination.path,
          includeJpgs: true,
        );
        expect(
          identical(
            container.read(exportFileOperationWorkflowProvider),
            active,
          ),
          isTrue,
          reason: '${active.phase}',
        );
      }
    });

    test(
      'delayed picker generation cannot overwrite a later drop open',
      () async {
        final picked = await Directory.systemTemp.createTemp(
          'export_picker_generation_picked_',
        );
        final dropped = await Directory.systemTemp.createTemp(
          'export_picker_generation_dropped_',
        );
        addTearDown(() => picked.delete(recursive: true));
        addTearDown(() => dropped.delete(recursive: true));
        await File(p.join(picked.path, 'PICKED.ARW')).writeAsString('picked');
        await File(
          p.join(dropped.path, 'DROPPED.ARW'),
        ).writeAsString('dropped');

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        final pickerResult = Completer<String>();
        final pickerGeneration = ctrl.beginOpenFolderSelection();
        expect(pickerGeneration, isNotNull);
        final delayedPicker = () async {
          final path = await pickerResult.future;
          await ctrl.openFolder(path, selectionGeneration: pickerGeneration);
        }();

        await ctrl.openFolder(dropped.path);
        pickerResult.complete(picked.path);
        await delayedPicker;

        final state = container.read(cullControllerProvider);
        expect(state.dir!.path, dropped.path);
        expect(state.pairs.single.stem, 'DROPPED');
      },
    );

    test(
      'captured export source generation rejects a replacement folder',
      () async {
        final source = await Directory.systemTemp.createTemp(
          'export_source_generation_source_',
        );
        final replacement = await Directory.systemTemp.createTemp(
          'export_source_generation_replacement_',
        );
        final destination = await Directory.systemTemp.createTemp(
          'export_source_generation_destination_',
        );
        addTearDown(() => source.delete(recursive: true));
        addTearDown(() => replacement.delete(recursive: true));
        addTearDown(() => destination.delete(recursive: true));
        await File(p.join(source.path, 'SOURCE.ARW')).writeAsString('source');
        await File(
          p.join(replacement.path, 'REPLACEMENT.ARW'),
        ).writeAsString('replacement');

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        await ctrl.openFolder(source.path);
        await ctrl.keep();
        final selectionRevision = ctrl.captureExportSelectionRevision();
        expect(selectionRevision, isNotNull);

        await ctrl.openFolder(replacement.path);
        await ctrl.prepareExport(
          destinationPath: destination.path,
          includeJpgs: true,
          selectionRevision: selectionRevision,
        );

        expect(
          container.read(exportFileOperationWorkflowProvider).phase,
          FileOperationWorkflowPhase.idle,
        );
        expect(
          container.read(cullControllerProvider).dir!.path,
          replacement.path,
        );
      },
    );

    test('captured export selection rejects a changed keep set', () async {
      final source = await Directory.systemTemp.createTemp(
        'export_selection_revision_source_',
      );
      final destination = await Directory.systemTemp.createTemp(
        'export_selection_revision_destination_',
      );
      addTearDown(() => source.delete(recursive: true));
      addTearDown(() => destination.delete(recursive: true));
      await File(p.join(source.path, 'A.ARW')).writeAsString('A');
      await File(p.join(source.path, 'B.ARW')).writeAsString('B');

      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openFolder(source.path);
      ctrl.goto(0);
      await ctrl.keep();
      final selectionRevision = ctrl.captureExportSelectionRevision();
      expect(selectionRevision, isNotNull);

      ctrl.goto(0);
      await ctrl.unflag();
      ctrl.goto(1);
      await ctrl.keep();
      await ctrl.prepareExport(
        destinationPath: destination.path,
        includeJpgs: true,
        selectionRevision: selectionRevision,
      );

      expect(
        container.read(exportFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.idle,
      );
    });

    test(
      'an older export intent cannot revive after a newer preview returns idle',
      () async {
        final source = await Directory.systemTemp.createTemp(
          'export_intent_epoch_source_',
        );
        final firstDestination = await Directory.systemTemp.createTemp(
          'export_intent_epoch_first_',
        );
        final secondDestination = await Directory.systemTemp.createTemp(
          'export_intent_epoch_second_',
        );
        addTearDown(() => source.delete(recursive: true));
        addTearDown(() => firstDestination.delete(recursive: true));
        addTearDown(() => secondDestination.delete(recursive: true));
        await File(p.join(source.path, 'A.ARW')).writeAsString('A');

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        await ctrl.openFolder(source.path);
        await ctrl.keep();
        final firstIntent = ctrl.beginExportIntent();
        final secondIntent = ctrl.beginExportIntent();
        expect(firstIntent, isNotNull);
        expect(secondIntent, isNotNull);

        await ctrl.prepareExport(
          destinationPath: secondDestination.path,
          includeJpgs: false,
          exportIntent: secondIntent,
        );
        expect(
          container.read(exportFileOperationWorkflowProvider).phase,
          FileOperationWorkflowPhase.preview,
        );
        container.read(exportFileOperationWorkflowProvider.notifier).discard();

        await ctrl.prepareExport(
          destinationPath: firstDestination.path,
          includeJpgs: true,
          exportIntent: firstIntent,
        );
        expect(
          container.read(exportFileOperationWorkflowProvider).phase,
          FileOperationWorkflowPhase.idle,
        );
      },
    );

    test(
      'a pending destination chooser locks folder and decision mutation',
      () async {
        final source = await Directory.systemTemp.createTemp(
          'export_pending_lock_source_',
        );
        final replacement = await Directory.systemTemp.createTemp(
          'export_pending_lock_replacement_',
        );
        addTearDown(() => source.delete(recursive: true));
        addTearDown(() => replacement.delete(recursive: true));
        await File(p.join(source.path, 'A.ARW')).writeAsString('A');
        await File(p.join(replacement.path, 'B.ARW')).writeAsString('B');

        final container = await makeContainer();
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        await ctrl.openFolder(source.path);
        await ctrl.keep();
        expect(ctrl.beginExportIntent(), isNotNull);

        await ctrl.unflag();
        await ctrl.openFolder(replacement.path);

        final state = container.read(cullControllerProvider);
        expect(state.dir!.path, source.path);
        expect(state.flags['A'], CullFlag.keep);
        expect(ctrl.beginOpenFolderSelection(), isNull);
      },
    );

    test(
      'an intervening workflow lifecycle invalidates a pending export intent',
      () async {
        final source = await Directory.systemTemp.createTemp(
          'export_workflow_epoch_source_',
        );
        final destination = await Directory.systemTemp.createTemp(
          'export_workflow_epoch_destination_',
        );
        addTearDown(() => source.delete(recursive: true));
        addTearDown(() => destination.delete(recursive: true));
        await File(p.join(source.path, 'A.ARW')).writeAsString('A');

        final workflow = _ManualWorkflowController();
        final container = await makeContainer(exportWorkflow: () => workflow);
        addTearDown(container.dispose);
        final ctrl = container.read(cullControllerProvider.notifier);
        container.read(exportFileOperationWorkflowProvider);
        await ctrl.openFolder(source.path);
        await ctrl.keep();
        final pendingIntent = ctrl.beginExportIntent();
        expect(pendingIntent, isNotNull);

        workflow.publish(
          FileOperationWorkflowState(phase: FileOperationWorkflowPhase.preview),
        );
        workflow.publish(FileOperationWorkflowState());
        await ctrl.prepareExport(
          destinationPath: destination.path,
          includeJpgs: true,
          exportIntent: pendingIntent,
        );

        expect(
          container.read(exportFileOperationWorkflowProvider).phase,
          FileOperationWorkflowPhase.idle,
        );
      },
    );
  });
}

final class _ManualWorkflowController extends FileOperationWorkflowController {
  @override
  FileOperationWorkflowState build() => FileOperationWorkflowState();

  void publish(FileOperationWorkflowState next) => state = next;
}

final class _InspectableCullController extends CullController {
  void publish(CullState next) => state = next;
}

final class _DelayedResolvePlatform extends DartFileOperationPlatform {
  final resolutionStarted = Completer<void>();
  final releaseResolution = Completer<void>();
  var _didDelay = false;

  @override
  Future<FileProviderItemReference> resolveDirectory(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    if (!_didDelay) {
      _didDelay = true;
      resolutionStarted.complete();
      await releaseResolution.future;
    }
    return super.resolveDirectory(access, selection);
  }
}
