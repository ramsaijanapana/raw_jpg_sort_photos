import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/sorter.dart';
import 'package:photo_sorter/core/models.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sorter_test_');
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

  group('sortPhotos — in-place move (same dir)', () {
    test('moves RAW to RAW/ subdir', () async {
      await createFile(p.join(tmp.path, 'photo.arw'));

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.rawCount, 1);
      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'photo.arw')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.arw')).existsSync(), isFalse);
    });

    test('moves JPG to JPG/ subdir', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'));

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.jpgCount, 1);
      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'JPG', 'photo.jpg')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.jpg')).existsSync(), isFalse);
    });

    test('moves both RAW and JPG files', () async {
      await createFile(p.join(tmp.path, 'a.nef'));
      await createFile(p.join(tmp.path, 'a.jpg'));
      await createFile(p.join(tmp.path, 'b.cr2'));

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.rawCount, 2);
      expect(result.jpgCount, 1);
      expect(result.skipped, 0);
      expect(File(p.join(tmp.path, 'RAW', 'a.nef')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'b.cr2')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'JPG', 'a.jpg')).existsSync(), isTrue);
    });

    test('originals are gone after in-place move', () async {
      await createFile(p.join(tmp.path, 'raw.raf'));
      await createFile(p.join(tmp.path, 'img.jpeg'));

      await sortPhotos(input: tmp, output: tmp);

      expect(File(p.join(tmp.path, 'raw.raf')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'img.jpeg')).existsSync(), isFalse);
    });
  });

  group('sortPhotos — copy to separate output', () {
    test('copies RAW files, originals remain', () async {
      await createFile(p.join(tmp.path, 'photo.arw'), 'raw_data');
      final outDir = await Directory.systemTemp.createTemp('sorter_out_');

      try {
        final result = await sortPhotos(input: tmp, output: outDir);

        expect(result.rawCount, 1);
        expect(result.moved, isFalse);
        // Original still exists
        expect(File(p.join(tmp.path, 'photo.arw')).existsSync(), isTrue);
        // Copy in output
        expect(File(p.join(outDir.path, 'RAW', 'photo.arw')).existsSync(), isTrue);
      } finally {
        await outDir.delete(recursive: true);
      }
    });

    test('copies JPG files, originals remain', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'), 'jpg_data');
      final outDir = await Directory.systemTemp.createTemp('sorter_out_');

      try {
        final result = await sortPhotos(input: tmp, output: outDir);

        expect(result.jpgCount, 1);
        expect(result.moved, isFalse);
        expect(File(p.join(tmp.path, 'photo.jpg')).existsSync(), isTrue);
        expect(File(p.join(outDir.path, 'JPG', 'photo.jpg')).existsSync(), isTrue);
      } finally {
        await outDir.delete(recursive: true);
      }
    });
  });

  group('sortPhotos — duplicates', () {
    test('skips file when destination already exists', () async {
      await createFile(p.join(tmp.path, 'photo.arw'), 'original');
      // Pre-create destination file
      await createFile(p.join(tmp.path, 'RAW', 'photo.arw'), 'existing');

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.skipped, 1);
      expect(result.rawCount, 0);
      // Existing dest file should be unchanged
      expect(
        File(p.join(tmp.path, 'RAW', 'photo.arw')).readAsStringSync(),
        'existing',
      );
    });

    test('skips duplicate jpg', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'), 'original_jpg');
      await createFile(p.join(tmp.path, 'JPG', 'photo.jpg'), 'existing_jpg');

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.skipped, 1);
      expect(result.jpgCount, 0);
    });
  });

  group('sortPhotos — non-photo files untouched', () {
    test('leaves non-RAW/JPG files in place', () async {
      await createFile(p.join(tmp.path, 'notes.txt'), 'text');
      await createFile(p.join(tmp.path, 'script.sh'), 'bash');
      await createFile(p.join(tmp.path, 'photo.arw'), 'raw');

      await sortPhotos(input: tmp, output: tmp);

      // Non-photo files should still exist in original location
      expect(File(p.join(tmp.path, 'notes.txt')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'script.sh')).existsSync(), isTrue);
    });
  });

  group('sortPhotos — progress callbacks', () {
    test('progress callback fires for each file', () async {
      await createFile(p.join(tmp.path, 'a.arw'));
      await createFile(p.join(tmp.path, 'b.nef'));
      await createFile(p.join(tmp.path, 'c.jpg'));

      final progressEvents = <SortProgress>[];
      await sortPhotos(
        input: tmp,
        output: tmp,
        onProgress: progressEvents.add,
      );

      expect(progressEvents.length, 3);
      // Total should always be 3
      expect(progressEvents.every((e) => e.total == 3), isTrue);
      // Current should go 1, 2, 3
      final currents = progressEvents.map((e) => e.current).toList()..sort();
      expect(currents, [1, 2, 3]);
    });

    test('progress event includes file name', () async {
      await createFile(p.join(tmp.path, 'myfile.arw'));

      final events = <SortProgress>[];
      await sortPhotos(input: tmp, output: tmp, onProgress: events.add);

      expect(events.length, 1);
      expect(events[0].fileName, 'myfile.arw');
    });
  });

  group('sortPhotos — zero photos', () {
    test('returns zero counts for empty folder', () async {
      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.rawCount, 0);
      expect(result.jpgCount, 0);
      expect(result.skipped, 0);
    });

    test('returns zero counts when folder has only non-photo files', () async {
      await createFile(p.join(tmp.path, 'readme.txt'));
      await createFile(p.join(tmp.path, 'data.csv'));

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.rawCount, 0);
      expect(result.jpgCount, 0);
      expect(result.skipped, 0);
    });

    test('returns SortResult with correct output path', () async {
      final result = await sortPhotos(input: tmp, output: tmp);
      expect(result.outputPath, isNotEmpty);
    });
  });

  group('sortPhotos — output dir does not exist yet (P0-6)', () {
    test('creates output dirs and copies without throwing', () async {
      await createFile(p.join(tmp.path, 'photo.arw'), 'raw_data');
      // Point at an output path that does not exist yet (resolveSymbolicLinks
      // would throw on this path).
      final outDir = Directory(p.join(tmp.path, 'does', 'not', 'exist', 'yet'));
      expect(outDir.existsSync(), isFalse);

      final result = await sortPhotos(input: tmp, output: outDir);

      expect(result.rawCount, 1);
      expect(result.moved, isFalse);
      expect(outDir.existsSync(), isTrue);
      expect(File(p.join(outDir.path, 'RAW', 'photo.arw')).existsSync(), isTrue);
      // Original preserved (copy, not move).
      expect(File(p.join(tmp.path, 'photo.arw')).existsSync(), isTrue);
    });

    test('same-dir move still detected as move', () async {
      await createFile(p.join(tmp.path, 'photo.nef'), 'raw');

      final result = await sortPhotos(input: tmp, output: tmp);

      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'photo.nef')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.nef')).existsSync(), isFalse);
    });
  });

  group('sortPhotos — rename failure fallback', () {
    test('handles pre-existing dest gracefully (skip path)', () async {
      // This tests the skip logic which exercises the dest.exists() check
      await createFile(p.join(tmp.path, 'dup.arw'), 'src_content');
      await createFile(p.join(tmp.path, 'RAW', 'dup.arw'), 'dest_content');

      // Should not throw, should skip
      final result = await sortPhotos(input: tmp, output: tmp);
      expect(result.skipped, greaterThanOrEqualTo(1));
    });
  });
}
