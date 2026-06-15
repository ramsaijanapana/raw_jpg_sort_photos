import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/scanner.dart';
import 'package:photo_sorter/core/models.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scanner_test_');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<File> createFile(String path, [String content = 'x']) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  group('scanRaws', () {
    test('finds RAW files in root folder', () async {
      await createFile(p.join(tmp.path, 'photo1.ARW'));
      await createFile(p.join(tmp.path, 'photo2.NEF'));
      await createFile(p.join(tmp.path, 'photo3.jpg')); // not RAW
      await createFile(p.join(tmp.path, 'notes.txt'));   // not RAW

      final raws = await scanRaws(tmp);
      expect(raws.length, 2);
      expect(raws.map((f) => p.basename(f.path)), containsAll(['photo1.ARW', 'photo2.NEF']));
    });

    test('also finds RAW files in RAW/ subdirectory', () async {
      await createFile(p.join(tmp.path, 'root.cr2'));
      await createFile(p.join(tmp.path, 'RAW', 'sub.arw'));
      await createFile(p.join(tmp.path, 'RAW', 'sub2.dng'));

      final raws = await scanRaws(tmp);
      expect(raws.length, 3);
      final names = raws.map((f) => p.basename(f.path)).toList();
      expect(names, containsAll(['root.cr2', 'sub.arw', 'sub2.dng']));
    });

    test('results are sorted by file name', () async {
      await createFile(p.join(tmp.path, 'z_photo.arw'));
      await createFile(p.join(tmp.path, 'a_photo.arw'));
      await createFile(p.join(tmp.path, 'm_photo.nef'));

      final raws = await scanRaws(tmp);
      final names = raws.map((f) => p.basename(f.path)).toList();
      expect(names, equals(['a_photo.arw', 'm_photo.nef', 'z_photo.arw']));
    });

    test('returns empty list when no RAW files exist', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'));
      await createFile(p.join(tmp.path, 'notes.txt'));

      final raws = await scanRaws(tmp);
      expect(raws, isEmpty);
    });

    test('returns empty list for empty directory', () async {
      final raws = await scanRaws(tmp);
      expect(raws, isEmpty);
    });

    test('skips RAW/ subdir if it does not exist', () async {
      await createFile(p.join(tmp.path, 'photo.arw'));
      // No RAW/ subdir

      final raws = await scanRaws(tmp);
      expect(raws.length, 1);
    });

    test('all supported raw extensions are recognized', () async {
      const exts = ['.arw', '.cr2', '.cr3', '.nef', '.raf', '.orf', '.dng', '.rw2', '.pef', '.srw'];
      for (final ext in exts) {
        await createFile(p.join(tmp.path, 'photo$ext'));
      }

      final raws = await scanRaws(tmp);
      expect(raws.length, exts.length);
    });
  });

  group('scanPairs', () {
    test('pairs RAW with companion JPG in root folder', () async {
      await createFile(p.join(tmp.path, 'DSC0001.arw'));
      await createFile(p.join(tmp.path, 'DSC0001.jpg'));

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 1);
      expect(pairs[0].stem, 'DSC0001');
      expect(pairs[0].jpg, isNotNull);
      expect(p.basename(pairs[0].jpg!.path), 'DSC0001.jpg');
    });

    test('finds JPG in JPG/ subdirectory', () async {
      await createFile(p.join(tmp.path, 'DSC0002.arw'));
      await createFile(p.join(tmp.path, 'JPG', 'DSC0002.jpg'));

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 1);
      expect(pairs[0].jpg, isNotNull);
      expect(p.basename(pairs[0].jpg!.path), 'DSC0002.jpg');
    });

    test('raw-only pair has null jpg', () async {
      await createFile(p.join(tmp.path, 'DSC0003.nef'));
      // No JPG companion

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 1);
      expect(pairs[0].stem, 'DSC0003');
      expect(pairs[0].jpg, isNull);
    });

    test('finds JPG with .JPG uppercase extension', () async {
      await createFile(p.join(tmp.path, 'IMG_001.cr2'));
      await createFile(p.join(tmp.path, 'IMG_001.JPG'));

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 1);
      expect(pairs[0].jpg, isNotNull);
      expect(p.basename(pairs[0].jpg!.path), 'IMG_001.JPG');
    });

    test('finds JPG with .jpeg extension', () async {
      await createFile(p.join(tmp.path, 'IMG_002.dng'));
      await createFile(p.join(tmp.path, 'IMG_002.jpeg'));

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 1);
      expect(pairs[0].jpg, isNotNull);
    });

    test('finds JPG with .JPEG uppercase extension', () async {
      await createFile(p.join(tmp.path, 'IMG_003.raf'));
      await createFile(p.join(tmp.path, 'IMG_003.JPEG'));

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 1);
      expect(pairs[0].jpg, isNotNull);
    });

    test('multiple raws each paired correctly', () async {
      await createFile(p.join(tmp.path, 'A.arw'));
      await createFile(p.join(tmp.path, 'A.jpg'));
      await createFile(p.join(tmp.path, 'B.nef'));
      // B has no jpg

      final pairs = await scanPairs(tmp);
      expect(pairs.length, 2);

      final pairA = pairs.firstWhere((pp) => pp.stem == 'A');
      expect(pairA.jpg, isNotNull);

      final pairB = pairs.firstWhere((pp) => pp.stem == 'B');
      expect(pairB.jpg, isNull);
    });

    test('pairs are sorted by stem name', () async {
      await createFile(p.join(tmp.path, 'Z.arw'));
      await createFile(p.join(tmp.path, 'A.nef'));

      final pairs = await scanPairs(tmp);
      expect(pairs[0].stem, 'A');
      expect(pairs[1].stem, 'Z');
    });

    test('returns empty list when no RAW files', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'));

      final pairs = await scanPairs(tmp);
      expect(pairs, isEmpty);
    });

    test('PhotoPair exposes correct types', () async {
      await createFile(p.join(tmp.path, 'test.cr2'));

      final pairs = await scanPairs(tmp);
      expect(pairs[0], isA<PhotoPair>());
      expect(pairs[0].raw, isA<File>());
      expect(pairs[0].stem, isA<String>());
    });
  });
}
