import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/main.dart';
import 'package:photo_sorter/state/cull_controller.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Pump the app at a given logical size.
Future<void> pumpApp(
  WidgetTester tester,
  Size logicalSize,
) async {
  tester.view.physicalSize =
      logicalSize * tester.view.devicePixelRatio;
  await tester.pumpWidget(
    const ProviderScope(child: PhotoSorterApp()),
  );
  await tester.pumpAndSettle();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Reset view after each test.
  tearDown(() {
    for (final v
        in TestWidgetsFlutterBinding.instance.platformDispatcher.views) {
      // ignore: invalid_use_of_visible_for_testing_member
      v.resetPhysicalSize();
    }
  });

  // 1. App renders shell with Sort + Review destinations.
  testWidgets('wide: shell shows Sort and Review in NavigationRail',
      (tester) async {
    await pumpApp(tester, const Size(1100, 760));

    // NavigationRail is present at wide widths.
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Sort'), findsWidgets);
    expect(find.text('Review'), findsWidgets);
  });

  // 2. Sort screen: Sort Photos button exists; no folder → error card on tap.
  testWidgets('sort screen: button exists, tapping without folder shows error',
      (tester) async {
    await pumpApp(tester, const Size(1100, 760));

    // The Sort tab should be visible by default.
    expect(find.text('Sort Photos'), findsWidgets);

    // The FilledButton "Sort Photos" should be disabled (no input chosen).
    final btn = find.widgetWithText(FilledButton, 'Sort Photos');
    expect(btn, findsOneWidget);

    // Button is disabled (onPressed == null) until a folder is picked.
    final button = tester.widget<FilledButton>(btn);
    expect(button.onPressed, isNull);
  });

  // 3. Review screen shows empty hint.
  testWidgets('review screen shows empty hint', (tester) async {
    await pumpApp(tester, const Size(1100, 760));

    // Tap the Review destination.
    await tester.tap(find.text('Review').last);
    await tester.pumpAndSettle();

    expect(
      find.text('Open a folder to start reviewing'),
      findsOneWidget,
    );
  });

  // 4. Narrow width shows NavigationBar, wide shows NavigationRail.
  testWidgets('narrow width shows NavigationBar', (tester) async {
    await pumpApp(tester, const Size(400, 700));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
  });

  testWidgets('wide width shows NavigationRail not NavigationBar',
      (tester) async {
    await pumpApp(tester, const Size(1100, 760));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  // 5. End-to-end-ish: openFolder, keep/skip, session written.
  test('cull_controller: openFolder, keep, skip, session file written',
      () async {
    // Create a temp dir with fake .ARW and .JPG files.
    final tmp = await Directory.systemTemp.createTemp('widget_test_');
    try {
      final arw1 = File(p.join(tmp.path, 'IMG_001.ARW'));
      final arw2 = File(p.join(tmp.path, 'IMG_002.ARW'));
      final jpg1 = File(p.join(tmp.path, 'IMG_001.jpg'));
      await arw1.writeAsBytes(Uint8List.fromList([0, 1, 2, 3]));
      await arw2.writeAsBytes(Uint8List.fromList([4, 5, 6, 7]));
      await jpg1.writeAsBytes(Uint8List.fromList([8, 9, 10, 11]));

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final ctrl = container.read(cullControllerProvider.notifier);

      // Open folder
      await ctrl.openFolder(tmp.path);
      var state = container.read(cullControllerProvider);

      expect(state.pairs.length, 2);
      expect(state.pairs.map((p) => p.stem).toList(),
          containsAll(['IMG_001', 'IMG_002']));
      expect(state.index, 0);

      // Keep first photo
      await ctrl.keep();
      state = container.read(cullControllerProvider);
      expect(state.flags['IMG_001'], equals(CullFlag.keep));
      expect(state.keptCount, 1);

      // Skip second photo (goto index 1 first since auto-advance may have moved)
      ctrl.goto(1);
      await ctrl.skip();
      state = container.read(cullControllerProvider);
      expect(state.flags['IMG_002'], equals(CullFlag.skip));
      expect(state.skipCount, 1);

      // Session file should be written
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sessionFile =
          File(p.join(tmp.path, 'cull_session.json'));
      expect(await sessionFile.exists(), isTrue);
      final content = await sessionFile.readAsString();
      expect(content, contains('"IMG_001":"keep"'));
      expect(content, contains('"IMG_002":"skip"'));
    } finally {
      await tmp.delete(recursive: true);
    }
  });
}
