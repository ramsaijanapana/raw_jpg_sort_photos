import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/sorter.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sorter_cancel_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<File> createFile(String path, [String content = 'data']) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  group('sortPhotos — shouldCancel', () {
    test('shouldCancel true immediately → cancelled:true, 0 processed', () async {
      await createFile(p.join(tmp.path, 'a.arw'));
      await createFile(p.join(tmp.path, 'b.nef'));
      await createFile(p.join(tmp.path, 'c.jpg'));

      final result = await sortPhotos(
        input: tmp,
        output: tmp,
        shouldCancel: () => true, // always cancel
      );

      expect(result.cancelled, isTrue);
      // No files were processed.
      expect(result.rawCount + result.jpgCount + result.skipped, 0);
    });

    test('shouldCancel after 2 files → partial counts, remaining untouched',
        () async {
      // Create 5 files — cancel fires after 2 iterations.
      final fileNames = ['a.arw', 'b.nef', 'c.cr2', 'd.jpg', 'e.jpeg'];
      for (final name in fileNames) {
        await createFile(p.join(tmp.path, name));
      }

      int callCount = 0;
      final result = await sortPhotos(
        input: tmp,
        output: tmp,
        shouldCancel: () {
          // Cancel starting from the 3rd check (i.e. after 2 files moved).
          callCount++;
          return callCount > 2;
        },
      );

      expect(result.cancelled, isTrue);
      // Partial: some files were sorted, but not all.
      final processed = result.rawCount + result.jpgCount + result.skipped;
      expect(processed, lessThan(fileNames.length));
      expect(processed, greaterThan(0));
    });

    test('shouldCancel always false → normal completion, cancelled:false', () async {
      await createFile(p.join(tmp.path, 'photo.arw'));
      await createFile(p.join(tmp.path, 'photo.jpg'));

      final result = await sortPhotos(
        input: tmp,
        output: tmp,
        shouldCancel: () => false,
      );

      expect(result.cancelled, isFalse);
      expect(result.rawCount, 1);
      expect(result.jpgCount, 1);
    });

    test('null shouldCancel → normal completion (backward compat)', () async {
      await createFile(p.join(tmp.path, 'photo.nef'));

      final result = await sortPhotos(
        input: tmp,
        output: tmp,
      );

      expect(result.cancelled, isFalse);
      expect(result.rawCount, 1);
    });
  });

  group('SortResult.cancelled field', () {
    test('default cancelled is false', () {
      const r = SortResult(
        rawCount: 0,
        jpgCount: 0,
        skipped: 0,
        moved: false,
        outputPath: '/tmp',
      );
      expect(r.cancelled, isFalse);
    });

    test('cancelled:true preserved', () {
      const r = SortResult(
        rawCount: 1,
        jpgCount: 0,
        skipped: 0,
        moved: true,
        outputPath: '/tmp',
        cancelled: true,
      );
      expect(r.cancelled, isTrue);
    });
  });
}
