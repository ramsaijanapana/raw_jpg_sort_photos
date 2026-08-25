import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/main.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';

class _WarningPickService extends FilePickService {
  _WarningPickService([this.result = _inaccessible]);

  final DirectoryPickResult result;

  static const DirectoryPickResult _inaccessible = (
    path: null,
    warning: directoryAccessWarning,
    folder: null,
  );

  @override
  Future<DirectoryPickResult> pickDirectory({String? title}) async => result;
}

Future<PrefsService> _prefs() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return PrefsService(prefs);
}

void main() {
  tearDown(() {
    for (final v
        in TestWidgetsFlutterBinding.instance.platformDispatcher.views) {
      // ignore: invalid_use_of_visible_for_testing_member
      v.resetPhysicalSize();
    }
  });

  testWidgets(
    'Review open-folder surfaces picker warning like Export (SnackBar + a11y)',
    (tester) async {
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      final prefs = await _prefs();
      final semantics = tester.ensureSemantics();
      addTearDown(semantics.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefsServiceProvider.overrideWithValue(prefs),
            filePickServiceProvider.overrideWithValue(_WarningPickService()),
          ],
          child: const PhotoSorterApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.text('Review').last);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Open a folder to start reviewing'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Open Folder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(directoryAccessWarning), findsOneWidget);
      expect(
        tester.getSemantics(find.text(directoryAccessWarning)),
        containsSemantics(label: directoryAccessWarning),
      );
      // Rejected pick must not pretend a folder opened.
      expect(find.text('Open a folder to start reviewing'), findsOneWidget);
      expect(find.text('No folder open'), findsOneWidget);
    },
  );

  testWidgets(
    'Review rejected pick keeps the already-open folder',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('review_warn_keep_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      for (final name in ['IMG_001.ARW', 'IMG_002.ARW']) {
        File(p.join(tmp.path, name)).writeAsBytesSync([0, 1, 2, 3]);
      }

      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      final prefs = await _prefs();
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(prefs),
          filePickServiceProvider.overrideWithValue(_WarningPickService()),
        ],
      );
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
        await container.read(cullControllerProvider.notifier).openFolder(
              tmp.path,
            );
      });
      await tester.pump(const Duration(milliseconds: 100));

      final before = container.read(cullControllerProvider);
      expect(before.pairs.length, 2);
      expect((before.dir as LocalFolder).path, tmp.path);

      await tester.tap(find.widgetWithText(FilledButton, 'Open Folder'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(directoryAccessWarning), findsOneWidget);

      final after = container.read(cullControllerProvider);
      expect(
        (after.dir as LocalFolder).path,
        (before.dir as LocalFolder).path,
      );
      expect(after.pairs.length, before.pairs.length);
      expect(after.index, before.index);
      expect(after.loading, isFalse);
      expect(after.flags, before.flags);
    },
  );

  testWidgets(
    'Review JPG filmstrip has no FileImage and uses the thumbnail/bytes seam',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('review_filmstrip_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'IMG_001.ARW')).writeAsBytesSync([0, 1, 2, 3]);
      File(p.join(tmp.path, 'IMG_001.jpg')).writeAsBytesSync([0, 1, 2, 3]);

      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      final prefs = await _prefs();
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(prefs),
        ],
      );
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
        await container.read(cullControllerProvider.notifier).openFolder(
              tmp.path,
            );
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = container.read(cullControllerProvider);
      expect(state.pairs.length, 1);
      expect(state.pairs.single.jpg, isNotNull);

      expect(find.text('IMG_001'), findsWidgets);
      expect(
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
            find.byType(Image).evaluate().isNotEmpty ||
            find.byIcon(Icons.broken_image).evaluate().isNotEmpty ||
            find.byIcon(Icons.image_not_supported).evaluate().isNotEmpty,
        isTrue,
      );
      for (final image in tester.widgetList<Image>(find.byType(Image))) {
        expect(_containsFileImage(image.image), isFalse);
      }
    },
  );
}

bool _containsFileImage(ImageProvider provider) {
  if (provider is FileImage) return true;
  if (provider is ResizeImage) {
    return _containsFileImage(provider.imageProvider);
  }
  return false;
}
