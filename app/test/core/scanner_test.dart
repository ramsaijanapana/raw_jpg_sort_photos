import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/scanner.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';

void main() {
  late Directory tmp;
  late LocalFolder folder;
  late IoStorageGateway gateway;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('scanner_test_');
    folder = LocalFolder(tmp.path);
    gateway = IoStorageGateway();
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

  Future<List<StorageEntry>> raws() => scanRaws(folder, gateway: gateway);
  Future<List<PhotoPair>> pairs() => scanPairs(folder, gateway: gateway);

  Matcher throwsInvalidArg() => throwsA(
        isA<StorageException>().having(
          (e) => e.code,
          'code',
          StorageException.invalidArg,
        ),
      );

  group('scanRaws', () {
    test('finds RAW files in root folder', () async {
      await createFile(p.join(tmp.path, 'photo1.ARW'));
      await createFile(p.join(tmp.path, 'photo2.NEF'));
      await createFile(p.join(tmp.path, 'photo3.jpg')); // not RAW
      await createFile(p.join(tmp.path, 'notes.txt'));   // not RAW

      final found = await raws();
      expect(found.length, 2);
      expect(found.map((f) => f.name), containsAll(['photo1.ARW', 'photo2.NEF']));
    });

    test('also finds RAW files in RAW/ subdirectory', () async {
      await createFile(p.join(tmp.path, 'root.cr2'));
      await createFile(p.join(tmp.path, 'RAW', 'sub.arw'));
      await createFile(p.join(tmp.path, 'RAW', 'sub2.dng'));

      final found = await raws();
      expect(found.length, 3);
      final names = found.map((f) => f.name).toList();
      expect(names, containsAll(['root.cr2', 'sub.arw', 'sub2.dng']));
    });

    test('results are sorted by file name', () async {
      await createFile(p.join(tmp.path, 'z_photo.arw'));
      await createFile(p.join(tmp.path, 'a_photo.arw'));
      await createFile(p.join(tmp.path, 'm_photo.nef'));

      final found = await raws();
      final names = found.map((f) => f.name).toList();
      expect(names, equals(['a_photo.arw', 'm_photo.nef', 'z_photo.arw']));
    });

    test('returns empty list when no RAW files exist', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'));
      await createFile(p.join(tmp.path, 'notes.txt'));

      expect(await raws(), isEmpty);
    });

    test('returns empty list for empty directory', () async {
      expect(await raws(), isEmpty);
    });

    test('skips RAW/ subdir if it does not exist', () async {
      await createFile(p.join(tmp.path, 'photo.arw'));
      // No RAW/ subdir

      final found = await raws();
      expect(found.length, 1);
    });

    test('all supported raw extensions are recognized', () async {
      const exts = ['.arw', '.cr2', '.cr3', '.nef', '.raf', '.orf', '.dng', '.rw2', '.pef', '.srw'];
      for (final ext in exts) {
        await createFile(p.join(tmp.path, 'photo$ext'));
      }

      final found = await raws();
      expect(found.length, exts.length);
    });
  });

  group('scanPairs', () {
    test('pairs RAW with companion JPG in root folder', () async {
      await createFile(p.join(tmp.path, 'DSC0001.arw'));
      await createFile(p.join(tmp.path, 'DSC0001.jpg'));

      final found = await pairs();
      expect(found.length, 1);
      expect(found[0].stem, 'DSC0001');
      expect(found[0].jpg, isNotNull);
      expect(found[0].jpg!.name, 'DSC0001.jpg');
    });

    test('finds JPG in JPG/ subdirectory', () async {
      await createFile(p.join(tmp.path, 'DSC0002.arw'));
      await createFile(p.join(tmp.path, 'JPG', 'DSC0002.jpg'));

      final found = await pairs();
      expect(found.length, 1);
      expect(found[0].jpg, isNotNull);
      expect(found[0].jpg!.name, 'DSC0002.jpg');
    });

    test('raw-only pair has null jpg', () async {
      await createFile(p.join(tmp.path, 'DSC0003.nef'));
      // No JPG companion

      final found = await pairs();
      expect(found.length, 1);
      expect(found[0].stem, 'DSC0003');
      expect(found[0].jpg, isNull);
    });

    test('finds JPG with .JPG uppercase extension', () async {
      await createFile(p.join(tmp.path, 'IMG_001.cr2'));
      await createFile(p.join(tmp.path, 'IMG_001.JPG'));

      final found = await pairs();
      expect(found.length, 1);
      expect(found[0].jpg, isNotNull);
      expect(found[0].jpg!.name, 'IMG_001.JPG');
    });

    test('finds JPG with .jpeg extension', () async {
      await createFile(p.join(tmp.path, 'IMG_002.dng'));
      await createFile(p.join(tmp.path, 'IMG_002.jpeg'));

      final found = await pairs();
      expect(found.length, 1);
      expect(found[0].jpg, isNotNull);
    });

    test('finds JPG with .JPEG uppercase extension', () async {
      await createFile(p.join(tmp.path, 'IMG_003.raf'));
      await createFile(p.join(tmp.path, 'IMG_003.JPEG'));

      final found = await pairs();
      expect(found.length, 1);
      expect(found[0].jpg, isNotNull);
    });

    test('multiple raws each paired correctly', () async {
      await createFile(p.join(tmp.path, 'A.arw'));
      await createFile(p.join(tmp.path, 'A.jpg'));
      await createFile(p.join(tmp.path, 'B.nef'));
      // B has no jpg

      final found = await pairs();
      expect(found.length, 2);

      final pairA = found.firstWhere((pp) => pp.stem == 'A');
      expect(pairA.jpg, isNotNull);

      final pairB = found.firstWhere((pp) => pp.stem == 'B');
      expect(pairB.jpg, isNull);
    });

    test('pairs are sorted by stem name', () async {
      await createFile(p.join(tmp.path, 'Z.arw'));
      await createFile(p.join(tmp.path, 'A.nef'));

      final found = await pairs();
      expect(found[0].stem, 'A');
      expect(found[1].stem, 'Z');
    });

    test('returns empty list when no RAW files', () async {
      await createFile(p.join(tmp.path, 'photo.jpg'));

      expect(await pairs(), isEmpty);
    });

    test('PhotoPair.raw is a StorageEntry and not a File', () async {
      await createFile(p.join(tmp.path, 'test.cr2'));

      final found = await pairs();
      expect(found[0], isA<PhotoPair>());
      expect(found[0].raw, isA<StorageEntry>());
      expect(found[0].raw, isNot(isA<File>()));
      expect(found[0].stem, isA<String>());
    });

    test('rejects LocalFolder content URI with invalid_arg before local I/O',
        () async {
      const uri = 'content://com.android.externalstorage.documents/tree/primary';
      await expectLater(
        scanPairs(const LocalFolder(uri), gateway: IoStorageGateway()),
        throwsInvalidArg(),
      );
    });
  });
}
