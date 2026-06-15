import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_sorter/main.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';

Future<ProviderContainer> makeContainer() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [prefsServiceProvider.overrideWithValue(PrefsService(prefs))],
  );
}

void main() {
  tearDown(() {
    for (final v
        in TestWidgetsFlutterBinding.instance.platformDispatcher.views) {
      // ignore: invalid_use_of_visible_for_testing_member
      v.resetPhysicalSize();
    }
  });

  // Progress bar: 6-pair folder, 2 decided → '2 / 6 decided' visible;
  // LinearProgressIndicator value 2/6.
  testWidgets('bottom bar shows progress and decided count', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('progress_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    for (var i = 1; i <= 6; i++) {
      File(p.join(tmp.path, 'IMG_00$i.ARW')).writeAsBytesSync([0, 1, 2, 3]);
    }

    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    final container = await makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PhotoSorterApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Switch to Review tab and open folder.
    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => container.read(cullControllerProvider.notifier).openFolder(tmp.path),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Decide 2 photos using runAsync to avoid fake-async issues with file I/O.
    final ctrl = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      ctrl.goto(0);
      await ctrl.keep();
      ctrl.goto(1);
      await ctrl.skip();
    });
    await tester.pump(const Duration(milliseconds: 150));

    // Expect '2 / 6 decided' text in bottom bar.
    expect(find.text('2 / 6 decided'), findsOneWidget);

    // Expect LinearProgressIndicator with value 2/6 ≈ 0.333.
    final indicator = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(indicator.value, closeTo(2.0 / 6.0, 0.001));
  });

  // Shift+/ opens shortcuts dialog.
  testWidgets('Shift+/ opens shortcuts dialog', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('shortcuts_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File(p.join(tmp.path, 'IMG_001.ARW')).writeAsBytesSync([0, 1, 2, 3]);

    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    final container = await makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PhotoSorterApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Switch to Review tab.
    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => container.read(cullControllerProvider.notifier).openFolder(tmp.path),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Press Shift+/ to open shortcuts dialog.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump(const Duration(milliseconds: 100));

    // Assert dialog is visible with at least one binding row.
    expect(find.text('Keyboard Shortcuts'), findsOneWidget);
    // Check for one of the binding labels.
    expect(find.textContaining('Navigate'), findsOneWidget);
  });
}
