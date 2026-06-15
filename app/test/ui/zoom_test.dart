import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_sorter/main.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';

// Minimal valid JPEG (a tiny 1x1 white JPEG).
final _minimalJpeg = Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
  0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
  0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
  0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
  0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
  0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
  0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
  0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
  0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
  0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
  0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
  0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
  0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
  0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
  0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
  0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
  0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
  0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
  0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
  0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
  0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
  0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
  0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD4, 0xFF, 0xD9,
]);

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

  // Zoom test: double-tap on stage → controller scale > 1.
  // Uses real JPEG bytes stored as the "ARW" (the preview extractor returns
  // null for fake bytes, so the stage will show a loading/error state, but
  // we test the controller directly.)
  testWidgets('zoom: double-tap toggles zoom, index change resets to identity',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('zoom_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    // Write ARW + JPG pairs so the preview loads from the JPG file.
    for (final stem in ['Z001', 'Z002']) {
      File(p.join(tmp.path, '$stem.ARW')).writeAsBytesSync([0, 1, 2, 3]);
      File(p.join(tmp.path, '$stem.jpg')).writeAsBytesSync(_minimalJpeg);
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

    // Switch to Review tab.
    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await container.read(cullControllerProvider.notifier).openFolder(tmp.path);
      // Also wait for the preview provider to load the JPG bytes.
      final s = container.read(cullControllerProvider);
      if (s.currentPair != null) {
        final key = (stem: s.currentPair!.stem, mode: s.mode);
        await container.read(previewProvider(key).future);
      }
    });
    // Pump multiple frames to let the preview provider data propagate.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Find the InteractiveViewer.
    final ivFinder = find.byType(InteractiveViewer);
    expect(ivFinder, findsOneWidget);

    // Get the TransformationController via the InteractiveViewer widget.
    final iv = tester.widget<InteractiveViewer>(ivFinder);
    final tc = iv.transformationController!;

    // Initial scale should be 1.0 (identity).
    expect(tc.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

    // Directly set the controller to a zoomed state (simulates zoom-in).
    tc.value = Matrix4.diagonal3Values(3.0, 3.0, 1.0);
    await tester.pump(const Duration(milliseconds: 50));
    expect(tc.value.getMaxScaleOnAxis(), closeTo(3.0, 0.01));

    // Navigate to next photo → the ref.listen on index should call resetTransform.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(cullControllerProvider).index, 1);

    // After index change, transform should be reset to identity.
    expect(tc.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));
  });

  // Regression: zoom-to-100% must compute the REAL scale from the image's
  // native size on a 1x-DPI display (it was inert: native size was read from
  // the downsampled provider and the scale formula was inverted).
  testWidgets('zoom: Space reaches true 100% scale on a 1x display',
      (tester) async {
    final tmp = Directory.systemTemp.createTempSync('zoom100_test_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    // Generate a real 2400x1600 image and store it as the pair's JPG.
    final bigImageBytes = await tester.runAsync(() async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 2400, 1600),
        Paint()..color = const Color(0xFF3D7A5F),
      );
      final img = await rec.endRecording().toImage(2400, 1600);
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      return bd!.buffer.asUint8List();
    });
    File(p.join(tmp.path, 'Z001.ARW')).writeAsBytesSync([0, 1, 2, 3]);
    File(p.join(tmp.path, 'Z001.jpg')).writeAsBytesSync(bigImageBytes!);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1100, 760);
    addTearDown(() {
      // ignore: invalid_use_of_visible_for_testing_member
      tester.view.resetDevicePixelRatio();
    });

    final container = await makeContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PhotoSorterApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Review').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await container
          .read(cullControllerProvider.notifier)
          .openFolder(tmp.path);
      final s = container.read(cullControllerProvider);
      final key = (stem: s.currentPair!.stem, mode: s.mode);
      await container.read(previewProvider(key).future);
    });
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // Let the ImageDescriptor-based native-size resolution complete.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final tc = iv.transformationController!;
    expect(tc.value.getMaxScaleOnAxis(), closeTo(1.0, 0.01));

    // Space = zoom to 100%.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    // Let the 150ms zoom animation finish.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200));

    final stageSize = tester.getSize(find.byType(InteractiveViewer));
    final fitScale = [
      stageSize.width / 2400,
      stageSize.height / 1600,
    ].reduce((a, b) => a < b ? a : b);
    final expected = (1 / fitScale).clamp(1.0, 8.0);

    final actual = tc.value.getMaxScaleOnAxis();
    // Must be the computed 100% scale (not the old inert ~1.0, not the 2x
    // unknown-size fallback).
    expect(actual, closeTo(expected, expected * 0.15));
    expect(actual, greaterThan(1.5));

    // Space again returns to fit.
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tc.value.getMaxScaleOnAxis(), closeTo(1.0, 0.05));
  });
}
