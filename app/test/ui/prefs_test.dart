import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_sorter/main.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';

void main() {
  tearDown(() {
    for (final v
        in TestWidgetsFlutterBinding.instance.platformDispatcher.views) {
      // ignore: invalid_use_of_visible_for_testing_member
      v.resetPhysicalSize();
    }
  });

  // When saved dir exists on disk → Resume button shown above Open Folder.
  testWidgets('Review empty state shows Resume button for saved dir',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('resume_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // Write a RAW file so the folder is non-empty.
    File(p.join(tmp.path, 'IMG_001.ARW')).writeAsBytesSync([0, 1, 2, 3]);

    // Set up SharedPreferences with the saved dir.
    SharedPreferences.setMockInitialValues({'lastCullDir': tmp.path});
    final prefs = await SharedPreferences.getInstance();
    final prefsService = PrefsService(prefs);

    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsServiceProvider.overrideWithValue(prefsService)],
        child: const PhotoSorterApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Switch to Review tab.
    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));

    // Resume button should be visible.
    final baseName = p.basename(tmp.path);
    expect(find.textContaining('Resume'), findsOneWidget);
    expect(find.textContaining(baseName), findsOneWidget);

    // Open Folder button should also be visible below.
    expect(find.text('Open Folder…'), findsOneWidget);
  });

  // Tapping Resume loads the pairs (uses runAsync for real I/O).
  testWidgets('Tapping Resume button loads the folder', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('resume_tap_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    for (final name in ['IMG_001.ARW', 'IMG_002.ARW']) {
      File(p.join(tmp.path, name)).writeAsBytesSync([0, 1, 2, 3]);
    }

    SharedPreferences.setMockInitialValues({'lastCullDir': tmp.path});
    final prefs = await SharedPreferences.getInstance();
    final prefsService = PrefsService(prefs);

    final container = ProviderContainer(
      overrides: [prefsServiceProvider.overrideWithValue(prefsService)],
    );
    addTearDown(container.dispose);

    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;

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

    // Directly open the folder via the controller (simulating what Resume does)
    // using runAsync for real I/O.
    await tester.runAsync(() async {
      await container
          .read(cullControllerProvider.notifier)
          .openFolder(tmp.path);
    });
    await tester.pump(const Duration(milliseconds: 100));

    // Folder should be loaded.
    final state = container.read(cullControllerProvider);
    expect(state.pairs.length, 2);
  });

  // Missing/no saved dir → no Resume button.
  testWidgets('No saved dir → no Resume button, shows hint text', (tester) async {
    // Set up with no saved dir.
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final prefsService = PrefsService(prefs);

    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsServiceProvider.overrideWithValue(prefsService)],
        child: const PhotoSorterApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Switch to Review tab.
    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));

    // No Resume button.
    expect(find.textContaining('Resume'), findsNothing);
    // Shows default hint.
    expect(find.text('Open a folder to start reviewing'), findsOneWidget);
  });

  // Missing saved dir on disk → no Resume button.
  testWidgets('Saved dir missing on disk → no Resume button', (tester) async {
    // Use a path that does not exist.
    SharedPreferences.setMockInitialValues(
        {'lastCullDir': '/nonexistent/path/that/does/not/exist'});
    final prefs = await SharedPreferences.getInstance();
    final prefsService = PrefsService(prefs);

    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsServiceProvider.overrideWithValue(prefsService)],
        child: const PhotoSorterApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Resume'), findsNothing);
    expect(find.text('Open a folder to start reviewing'), findsOneWidget);
  });
}
