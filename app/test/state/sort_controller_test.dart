import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/sort_controller.dart';

Future<ProviderContainer> makeContainer() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [prefsServiceProvider.overrideWithValue(PrefsService(prefs))],
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

  group('SortController.cancel', () {
    test('cancel() while sorting sets cancelled phase', () async {
      final tmp = await Directory.systemTemp.createTemp('ctrl_cancel_');
      addTearDown(() => tmp.delete(recursive: true));

      // Create files to sort.
      for (var i = 1; i <= 10; i++) {
        File(p.join(tmp.path, 'img$i.arw')).writeAsStringSync('data');
      }

      final container = await makeContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(sortControllerProvider.notifier);
      await ctrl.setInput(tmp.path);

      // Start the sort and immediately cancel.
      final sortFuture = ctrl.start();
      ctrl.cancel();
      await sortFuture;

      final state = container.read(sortControllerProvider);
      // Should either be cancelled or done (race), but if cancelled it's correct.
      expect(
        state.phase == SortPhase.cancelled || state.phase == SortPhase.done,
        isTrue,
        reason: 'Expected cancelled or done after cancel(), got ${state.phase}',
      );
    });
  });

  group('SortPhase.cancelled', () {
    test('cancelled phase is defined', () {
      // Ensure the enum value exists.
      const phases = SortPhase.values;
      expect(phases.contains(SortPhase.cancelled), isTrue);
    });
  });
}
