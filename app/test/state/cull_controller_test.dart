import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';

/// Returns a [ProviderContainer] with a no-op [PrefsService] override.
Future<ProviderContainer> makeContainer() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [prefsServiceProvider.overrideWithValue(PrefsService(prefs))],
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
    test('three keep() calls within 120ms fire only one auto-advance',
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

      // Fire three keep() in quick succession (each cancels the prior timer).
      ctrl.keep();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      ctrl.keep();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      ctrl.keep();

      // Let all pending microtasks/I/O drain but NOT the 120ms timer yet.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Each keep cancels the prior timer; the last one has not fired yet.
      // Index should still be 0 (no advance yet).
      expect(container.read(cullControllerProvider).index, 0);

      // Wait well past the 120ms advance timer.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Only one auto-advance: index moves to the first undecided after 0.
      // All three keeps flagged the SAME pair (index 0, IMG_001) because no
      // advance happened between them, so the next undecided is index 1.
      final state = container.read(cullControllerProvider);
      expect(state.index, 1);
      // Exactly one pair was kept.
      expect(state.keptCount, 1);
      expect(state.flags['IMG_001'], CullFlag.keep);
    });
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
      await File(p.join(dirB.path, 'cull_session.json'))
          .writeAsString('{"B_001":"keep"}');

      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);

      // Start A then immediately B, then await both.
      final fa = ctrl.openFolder(dirA.path);
      final fb = ctrl.openFolder(dirB.path);
      await Future.wait([fa, fb]);

      final state = container.read(cullControllerProvider);
      // Final committed state must be folder B's pairs and flags.
      expect(state.pairs.map((e) => e.stem).toList()..sort(),
          ['B_001', 'B_002', 'B_003']);
      expect(state.flags['B_001'], CullFlag.keep);
      expect(state.dir!.path, dirB.path);
    });
  });

  // -------------------------------------------------------------------------
  // Undo tests (Wave 1 - spec §1.2)
  // -------------------------------------------------------------------------

  group('undo stack', () {
    test('flag K, X, K on 3 fake pairs → undo() restores in reverse order',
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
    });

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
}
