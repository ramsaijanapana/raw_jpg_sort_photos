import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/sorter.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';

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

  Future<SortResult> sort(
    Directory input,
    Directory output, {
    void Function(SortProgress)? onProgress,
    bool Function()? shouldCancel,
    StorageGateway? gateway,
  }) {
    return sortPhotos(
      input: LocalFolder(input.path),
      output: LocalFolder(output.path),
      gateway: gateway ?? IoStorageGateway(),
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
  }

  Matcher throwsInvalidArg() => throwsA(
        isA<StorageException>().having(
          (e) => e.code,
          'code',
          StorageException.invalidArg,
        ),
      );

  group('sortPhotos — in-place move (same dir)', () {
    test('moves RAW to RAW/ subdir', () async {
      await createFile(p.join(tmp.path, 'photo.arw'));

      final result = await sort(tmp, tmp);

      expect(result.rawCount, 1);
      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'photo.arw')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.arw')).existsSync(), isFalse);
    });

    test('moves JPG to JPG/ subdir', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'));

      final result = await sort(tmp, tmp);

      expect(result.jpgCount, 1);
      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'JPG', 'photo.jpg')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.jpg')).existsSync(), isFalse);
    });

    test('moves both RAW and JPG files', () async {
      await createFile(p.join(tmp.path, 'a.nef'));
      await createFile(p.join(tmp.path, 'a.jpg'));
      await createFile(p.join(tmp.path, 'b.cr2'));

      final result = await sort(tmp, tmp);

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

      await sort(tmp, tmp);

      expect(File(p.join(tmp.path, 'raw.raf')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'img.jpeg')).existsSync(), isFalse);
    });

    test('second in-place file does not fail when RAW/ already exists', () async {
      await createFile(p.join(tmp.path, 'first.arw'));
      await createFile(p.join(tmp.path, 'second.nef'));

      final result = await sort(tmp, tmp);

      expect(result.rawCount, 2);
      expect(File(p.join(tmp.path, 'RAW', 'first.arw')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'second.nef')).existsSync(), isTrue);
    });
  });

  group('sortPhotos — copy to separate output', () {
    test('copies RAW files, originals remain', () async {
      await createFile(p.join(tmp.path, 'photo.arw'), 'raw_data');
      final outDir = await Directory.systemTemp.createTemp('sorter_out_');

      try {
        final result = await sort(tmp, outDir);

        expect(result.rawCount, 1);
        expect(result.moved, isFalse);
        expect(File(p.join(tmp.path, 'photo.arw')).existsSync(), isTrue);
        expect(File(p.join(outDir.path, 'RAW', 'photo.arw')).existsSync(), isTrue);
      } finally {
        await outDir.delete(recursive: true);
      }
    });

    test('copies JPG files, originals remain', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'), 'jpg_data');
      final outDir = await Directory.systemTemp.createTemp('sorter_out_');

      try {
        final result = await sort(tmp, outDir);

        expect(result.jpgCount, 1);
        expect(result.moved, isFalse);
        expect(File(p.join(tmp.path, 'photo.jpg')).existsSync(), isTrue);
        expect(File(p.join(outDir.path, 'JPG', 'photo.jpg')).existsSync(), isTrue);
      } finally {
        await outDir.delete(recursive: true);
      }
    });

    test('cross-folder copies preserve source and report moved == false', () async {
      await createFile(p.join(tmp.path, 'kept.arw'), 'raw_data');
      final outDir = await Directory.systemTemp.createTemp('sorter_cross_');

      try {
        final result = await sort(tmp, outDir);
        expect(result.moved, isFalse);
        expect(result.rawCount, 1);
        expect(File(p.join(tmp.path, 'kept.arw')).readAsStringSync(), 'raw_data');
        expect(
          File(p.join(outDir.path, 'RAW', 'kept.arw')).readAsStringSync(),
          'raw_data',
        );
      } finally {
        await outDir.delete(recursive: true);
      }
    });
  });

  group('sortPhotos — duplicates', () {
    test('skips file when destination already exists', () async {
      await createFile(p.join(tmp.path, 'photo.arw'), 'original');
      await createFile(p.join(tmp.path, 'RAW', 'photo.arw'), 'existing');

      final result = await sort(tmp, tmp);

      expect(result.skipped, 1);
      expect(result.rawCount, 0);
      expect(
        File(p.join(tmp.path, 'RAW', 'photo.arw')).readAsStringSync(),
        'existing',
      );
    });

    test('skips duplicate jpg', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'), 'original_jpg');
      await createFile(p.join(tmp.path, 'JPG', 'photo.jpg'), 'existing_jpg');

      final result = await sort(tmp, tmp);

      expect(result.skipped, 1);
      expect(result.jpgCount, 0);
    });

    test('destination-exists skip preserves bytes and counts', () async {
      await createFile(p.join(tmp.path, 'dup.arw'), 'src_bytes');
      await createFile(p.join(tmp.path, 'RAW', 'dup.arw'), 'dest_bytes');

      final result = await sort(tmp, tmp);
      expect(result.skipped, 1);
      expect(result.rawCount, 0);
      expect(result.jpgCount, 0);
      expect(File(p.join(tmp.path, 'dup.arw')).readAsStringSync(), 'src_bytes');
      expect(
        File(p.join(tmp.path, 'RAW', 'dup.arw')).readAsStringSync(),
        'dest_bytes',
      );
    });
  });

  group('sortPhotos — non-photo files untouched', () {
    test('leaves non-RAW/JPG files in place', () async {
      await createFile(p.join(tmp.path, 'notes.txt'), 'text');
      await createFile(p.join(tmp.path, 'script.sh'), 'bash');
      await createFile(p.join(tmp.path, 'photo.arw'), 'raw');

      await sort(tmp, tmp);

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
      await sort(tmp, tmp, onProgress: progressEvents.add);

      expect(progressEvents.length, 3);
      expect(progressEvents.every((e) => e.total == 3), isTrue);
      final currents = progressEvents.map((e) => e.current).toList()..sort();
      expect(currents, [1, 2, 3]);
    });

    test('progress event includes file name', () async {
      await createFile(p.join(tmp.path, 'myfile.arw'));

      final events = <SortProgress>[];
      await sort(tmp, tmp, onProgress: events.add);

      expect(events.length, 1);
      expect(events[0].fileName, 'myfile.arw');
    });
  });

  group('sortPhotos — zero photos', () {
    test('returns zero counts for empty folder', () async {
      final result = await sort(tmp, tmp);

      expect(result.rawCount, 0);
      expect(result.jpgCount, 0);
      expect(result.skipped, 0);
    });

    test('returns zero counts when folder has only non-photo files', () async {
      await createFile(p.join(tmp.path, 'readme.txt'));
      await createFile(p.join(tmp.path, 'data.csv'));

      final result = await sort(tmp, tmp);

      expect(result.rawCount, 0);
      expect(result.jpgCount, 0);
      expect(result.skipped, 0);
    });

    test('returns SortResult with correct output path', () async {
      final result = await sort(tmp, tmp);
      expect(result.outputPath, tmp.path);
    });
  });

  group('sortPhotos — output dir does not exist yet (P0-6)', () {
    test('creates output dirs and copies without throwing', () async {
      await createFile(p.join(tmp.path, 'photo.arw'), 'raw_data');
      final outDir = Directory(p.join(tmp.path, 'does', 'not', 'exist', 'yet'));
      expect(outDir.existsSync(), isFalse);

      final result = await sort(tmp, outDir);

      expect(result.rawCount, 1);
      expect(result.moved, isFalse);
      expect(outDir.existsSync(), isTrue);
      expect(File(p.join(outDir.path, 'RAW', 'photo.arw')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.arw')).existsSync(), isTrue);
    });

    test('same-dir move still detected as move', () async {
      await createFile(p.join(tmp.path, 'photo.nef'), 'raw');

      final result = await sort(tmp, tmp);

      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'photo.nef')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'photo.nef')).existsSync(), isFalse);
    });
  });

  group('sortPhotos — rename failure fallback', () {
    test('handles pre-existing dest gracefully (skip path)', () async {
      await createFile(p.join(tmp.path, 'dup.arw'), 'src_content');
      await createFile(p.join(tmp.path, 'RAW', 'dup.arw'), 'dest_content');

      final result = await sort(tmp, tmp);
      expect(result.skipped, greaterThanOrEqualTo(1));
    });
  });

  group('sortPhotos — gateway seams', () {
    test('same-folder symlink is treated as move, not cross-folder copy',
        () async {
      await createFile(p.join(tmp.path, 'linked.arw'), 'raw');
      final link = Link(p.join(Directory.systemTemp.path,
          'sorter_symlink_${tmp.hashCode}'));
      addTearDown(() async {
        if (await link.exists()) await link.delete();
      });
      await link.create(tmp.path);

      final result = await sortPhotos(
        input: LocalFolder(tmp.path),
        output: LocalFolder(link.path),
        gateway: IoStorageGateway(),
      );

      expect(result.moved, isTrue);
      expect(File(p.join(tmp.path, 'linked.arw')).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'RAW', 'linked.arw')).existsSync(), isTrue);
    });

    test(
        'injected rename/delete failure produces incomplete_move, leaves source, does not count success',
        () async {
      await createFile(p.join(tmp.path, 'stuck.arw'), 'raw');
      final failing = IoStorageGateway(
        tryRename: (source, destPath) async {
          throw FileSystemException('rename blocked', source.path);
        },
        deleteSource: (file) async {
          throw FileSystemException('delete blocked', file.path);
        },
      );

      await expectLater(
        sort(tmp, tmp, gateway: failing),
        throwsA(
          isA<StorageException>().having(
            (e) => e.code,
            'code',
            StorageException.incompleteMove,
          ),
        ),
      );
      expect(File(p.join(tmp.path, 'stuck.arw')).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'stuck.arw')).existsSync(), isTrue);
    });

    test('rejects LocalFolder content URI with invalid_arg before local I/O',
        () async {
      const uri = 'content://com.android.externalstorage.documents/tree/primary';
      await expectLater(
        sortPhotos(
          input: const LocalFolder(uri),
          output: const LocalFolder(uri),
          gateway: IoStorageGateway(),
        ),
        throwsInvalidArg(),
      );
    });
  });
}
