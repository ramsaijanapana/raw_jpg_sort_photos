import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/services/file_pick_service.dart';

void main() {
  group('interpretPickedDirectory', () {
    test('cancel returns no path, no warning, and no folder', () async {
      final result = await interpretPickedDirectory(null);
      expect(result.path, isNull);
      expect(result.warning, isNull);
      expect(result.folder, isNull);
    });

    test('rejects content URIs with the accessibility warning', () async {
      final result = await interpretPickedDirectory(
        'content://com.android.externalstorage.documents/tree/primary%3ADCIM',
      );
      expect(result.path, isNull);
      expect(result.warning, directoryAccessWarning);
      expect(result.folder, isNull);
    });

    test('rejects http(s) URLs with the accessibility warning', () async {
      final httpResult =
          await interpretPickedDirectory('http://example.com/photos');
      expect(httpResult.path, isNull);
      expect(httpResult.warning, directoryAccessWarning);
      expect(httpResult.folder, isNull);

      final httpsResult =
          await interpretPickedDirectory('https://example.com/photos');
      expect(httpsResult.path, isNull);
      expect(httpsResult.warning, directoryAccessWarning);
      expect(httpsResult.folder, isNull);
    });

    test('rejects NUL-containing input with the accessibility warning',
        () async {
      final result = await interpretPickedDirectory('/tmp/\u0000photos');
      expect(result.path, isNull);
      expect(result.warning, directoryAccessWarning);
      expect(result.folder, isNull);
    });

    test('accepts a real directory on this host as LocalFolder', () async {
      final tmp = Directory.systemTemp.createTempSync('pick_ok_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final result = await interpretPickedDirectory(tmp.path);
      expect(result.warning, isNull);
      expect(result.path, tmp.path);
      expect(result.folder, isA<LocalFolder>());
      expect((result.folder as LocalFolder).path, tmp.path);
    });

    test('accepts a file URL for a real directory on this host', () async {
      final tmp = Directory.systemTemp.createTempSync('pick_fileurl_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final fileUrl = Uri.file(tmp.path).toString();
      final localPath = Uri.file(tmp.path).toFilePath();
      final result = await interpretPickedDirectory(fileUrl);
      expect(result.warning, isNull);
      expect(result.path, localPath);
      expect(result.folder, isA<LocalFolder>());
      expect((result.folder as LocalFolder).path, localPath);
    });

    test('Windows drive path that does not exist on this host warns', () async {
      final result = await interpretPickedDirectory(r'Z:\no-such-photo-sorter');
      expect(result.path, isNull);
      expect(result.warning, directoryAccessWarning);
      expect(result.folder, isNull);
    });
  });
}
