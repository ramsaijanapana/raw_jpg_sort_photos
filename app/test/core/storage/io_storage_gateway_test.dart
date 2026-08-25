import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';

Matcher throwsStorage(String code) => throwsA(
      isA<StorageException>().having((e) => e.code, 'code', code),
    );

void main() {
  late Directory tmp;
  late IoStorageGateway gw;
  late LocalFolder folder;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('io_gateway_');
    gw = IoStorageGateway();
    folder = LocalFolder(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('FolderRef value identity', () {
    test('LocalFolder equality is path-string based, not object identity', () {
      const a = LocalFolder('/tmp/shoot');
      const b = LocalFolder('/tmp/shoot');
      const c = LocalFolder('/tmp/other');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(identical(a, b), isFalse);
    });

    test('SafTree equality is field based, not object identity', () {
      const a = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'primary',
        displayName: 'DCIM',
      );
      const b = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'primary',
        displayName: 'DCIM',
      );
      const otherUri = SafTree(
        treeUri: 'content://auth/tree/other',
        documentId: 'primary',
        displayName: 'DCIM',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(otherUri));
      expect(a, isNot(const LocalFolder('content://auth/tree/primary')));
    });

    test('StorageEntry equality is value based and is not a File', () {
      const folderA = LocalFolder('/tmp/shoot');
      const a = StorageEntry(
        folder: folderA,
        name: 'a.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        localPath: '/tmp/shoot/a.arw',
        size: 3,
      );
      const b = StorageEntry(
        folder: LocalFolder('/tmp/shoot'),
        name: 'a.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        localPath: '/tmp/shoot/a.arw',
        size: 3,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(isA<File>()));
    });
  });

  group('list, lookup, and create', () {
    test('exists is true for a real folder and false when missing', () async {
      expect(await gw.exists(folder), isTrue);
      expect(
        await gw.exists(LocalFolder(p.join(tmp.path, 'missing'))),
        isFalse,
      );
    });

    test('creates a directory and file, then lists and looks them up', () async {
      await gw.createDirectory(folder, 'RAW');
      final created = await gw.createFile(
        folder,
        'shot.arw',
        mimeType: 'application/octet-stream',
        parentDocumentId: 'RAW',
      );

      expect(created.folder, folder);
      expect(created.name, 'shot.arw');
      expect(created.documentId, isNull);
      expect(created.localPath, p.join(tmp.path, 'RAW', 'shot.arw'));
      expect(created.mimeType, 'application/octet-stream');
      expect(created.isDirectory, isFalse);
      expect(created, isNot(isA<File>()));

      final rawDir = await gw.childByName(folder, 'RAW');
      expect(rawDir, isNotNull);
      expect(rawDir!.isDirectory, isTrue);
      expect(rawDir.localPath, p.join(tmp.path, 'RAW'));
      expect(rawDir.documentId, isNull);

      expect(await gw.childByName(folder, 'nope'), isNull);

      final rootKids = await gw.listChildren(folder);
      expect(rootKids.map((e) => e.name).toList(), ['RAW']);

      final rawKids = await gw.listChildren(folder, childDocumentId: 'RAW');
      expect(rawKids.single.name, 'shot.arw');
      expect(rawKids.single.localPath, created.localPath);
    });

    test('createDirectory and createFile refuse collisions', () async {
      await gw.createDirectory(folder, 'JPG');
      await expectLater(
        gw.createDirectory(folder, 'JPG'),
        throwsStorage(StorageException.alreadyExists),
      );

      await gw.createFile(folder, 'a.jpg', mimeType: 'image/jpeg');
      await expectLater(
        gw.createFile(folder, 'a.jpg', mimeType: 'image/jpeg'),
        throwsStorage(StorageException.alreadyExists),
      );
    });
  });

  group('read, range, length, and write', () {
    test('writes bytes and reads all, range, and length', () async {
      final file = await gw.createFile(
        folder,
        'note.bin',
        mimeType: 'application/octet-stream',
      );
      final bytes = Uint8List.fromList([10, 20, 30, 40, 50]);
      await gw.writeBytes(file, bytes);

      expect(await gw.byteLength(file), 5);
      expect(await gw.readAll(file), bytes);
      expect(await gw.readRange(file, offset: 1, length: 3), [20, 30, 40]);
      expect(await gw.readRange(file, offset: 4, length: 8), [50]);
    });

    test('readRange rejects a negative offset', () async {
      final file = await gw.createFile(
        folder,
        'note.bin',
        mimeType: 'application/octet-stream',
      );
      await gw.writeBytes(file, Uint8List.fromList([1]));
      await expectLater(
        gw.readRange(file, offset: -1, length: 1),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });

  group('copy overwrite policy', () {
    test('no-overwrite copy keeps source and fails when dest exists', () async {
      final source = await gw.createFile(
        folder,
        'src.arw',
        mimeType: 'application/octet-stream',
      );
      await gw.writeBytes(source, Uint8List.fromList([1, 2, 3]));
      await gw.createDirectory(folder, 'RAW');

      await gw.copyFile(
        source,
        folder,
        'src.arw',
        destParentDocumentId: 'RAW',
        overwrite: false,
      );
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(
        File(p.join(tmp.path, 'RAW', 'src.arw')).readAsBytesSync(),
        [1, 2, 3],
      );

      await expectLater(
        gw.copyFile(
          source,
          folder,
          'src.arw',
          destParentDocumentId: 'RAW',
          overwrite: false,
        ),
        throwsStorage(StorageException.alreadyExists),
      );
    });

    test('overwrite copy replaces dest bytes and keeps source', () async {
      final source = await gw.createFile(
        folder,
        'src.arw',
        mimeType: 'application/octet-stream',
      );
      await gw.writeBytes(source, Uint8List.fromList([9, 9]));
      await gw.createDirectory(folder, 'RAW');
      final destFile = File(p.join(tmp.path, 'RAW', 'src.arw'));
      await destFile.writeAsBytes([1]);

      await gw.copyFile(
        source,
        folder,
        'src.arw',
        destParentDocumentId: 'RAW',
        overwrite: true,
      );
      expect(destFile.readAsBytesSync(), [9, 9]);
      expect(File(source.localPath!).existsSync(), isTrue);
    });
  });

  group('same-folder identity', () {
    test('matches LocalFolder instances that share a canonical path', () async {
      expect(await gw.isSameFolder(folder, LocalFolder(tmp.path)), isTrue);
      expect(
        await gw.isSameFolder(folder, LocalFolder(p.join(tmp.path, 'other'))),
        isFalse,
      );
    });

    test('matches a local folder through a symlink', () async {
      final real = await Directory(p.join(tmp.path, 'real')).create();
      final linkPath = p.join(tmp.path, 'alias');
      await Link(linkPath).create(real.path);
      expect(
        await gw.isSameFolder(LocalFolder(real.path), LocalFolder(linkPath)),
        isTrue,
      );
    });

    test('missing local paths compare via normalized absolute fallback',
        () async {
      final missing = p.join(tmp.path, 'does-not-exist');
      expect(
        await gw.isSameFolder(LocalFolder(missing), LocalFolder(missing)),
        isTrue,
      );
      expect(
        await gw.isSameFolder(
          LocalFolder(missing),
          LocalFolder(p.join(tmp.path, 'other-missing')),
        ),
        isFalse,
      );
    });

    test('SafTree same-folder uses normalized tree URI, not object identity',
        () async {
      const a = SafTree(
        treeUri:
            'content://com.Android.externalstorage.documents/tree/primary%3ADCIM',
        documentId: 'primary:DCIM',
        displayName: 'DCIM',
      );
      const b = SafTree(
        treeUri:
            'content://com.android.externalstorage.documents/tree/primary%3ADCIM',
        documentId: 'other',
        displayName: 'Other',
      );
      expect(a, isNot(b));
      expect(await gw.isSameFolder(a, b), isTrue);
      expect(await gw.isSameFolder(a, folder), isFalse);
    });
  });

  group('move, delete, and missing source', () {
    test('same-folder move renames into a child directory', () async {
      final source = await gw.createFile(
        folder,
        'pic.arw',
        mimeType: 'application/octet-stream',
      );
      await gw.writeBytes(source, Uint8List.fromList([7, 8]));
      await gw.createDirectory(folder, 'RAW');

      final outcome = await gw.moveFile(
        source,
        folder,
        'pic.arw',
        destParentDocumentId: 'RAW',
      );
      expect(outcome, MoveOutcome.renamed);
      expect(File(source.localPath!).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'RAW', 'pic.arw')).readAsBytesSync(), [7, 8]);
    });

    test('cross-folder move copies and leaves the source', () async {
      final destDir = await Directory(p.join(tmp.path, 'out')).create();
      final destFolder = LocalFolder(destDir.path);
      final source = await gw.createFile(
        folder,
        'pic.arw',
        mimeType: 'application/octet-stream',
      );
      await gw.writeBytes(source, Uint8List.fromList([4]));

      final outcome = await gw.moveFile(source, destFolder, 'pic.arw');
      expect(outcome, MoveOutcome.copiedSourceRemains);
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(File(p.join(destDir.path, 'pic.arw')).readAsBytesSync(), [4]);
    });

    test('copy-delete fallback reports copiedAndDeleted', () async {
      final fallback = IoStorageGateway(
        tryRename: (source, destPath) async {
          throw const FileSystemException('cross-device');
        },
      );
      final source = await fallback.createFile(
        folder,
        'pic.arw',
        mimeType: 'application/octet-stream',
      );
      await fallback.writeBytes(source, Uint8List.fromList([1, 2, 3, 4]));
      await fallback.createDirectory(folder, 'RAW');

      final outcome = await fallback.moveFile(
        source,
        folder,
        'pic.arw',
        destParentDocumentId: 'RAW',
      );
      expect(outcome, MoveOutcome.copiedAndDeleted);
      expect(File(source.localPath!).existsSync(), isFalse);
      expect(
        File(p.join(tmp.path, 'RAW', 'pic.arw')).readAsBytesSync(),
        [1, 2, 3, 4],
      );
    });

    test('incomplete source delete throws and does not claim moved', () async {
      final fallback = IoStorageGateway(
        tryRename: (source, destPath) async {
          throw const FileSystemException('cross-device');
        },
        deleteSource: (file) async {
          throw const FileSystemException('busy');
        },
      );
      final source = await fallback.createFile(
        folder,
        'pic.arw',
        mimeType: 'application/octet-stream',
      );
      await fallback.writeBytes(source, Uint8List.fromList([5]));
      await fallback.createDirectory(folder, 'RAW');

      await expectLater(
        fallback.moveFile(
          source,
          folder,
          'pic.arw',
          destParentDocumentId: 'RAW',
        ),
        throwsStorage(StorageException.incompleteMove),
      );
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(File(p.join(tmp.path, 'RAW', 'pic.arw')).existsSync(), isTrue);
    });

    test('missing source operations fail explicitly', () async {
      final ghost = StorageEntry(
        folder: folder,
        name: 'ghost.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        localPath: p.join(tmp.path, 'ghost.arw'),
      );
      await expectLater(
        gw.readAll(ghost),
        throwsStorage(StorageException.notFound),
      );
      await expectLater(
        gw.copyFile(ghost, folder, 'out.arw', overwrite: false),
        throwsStorage(StorageException.notFound),
      );
      await expectLater(
        gw.moveFile(ghost, folder, 'out.arw'),
        throwsStorage(StorageException.notFound),
      );
      await expectLater(
        gw.deleteEntry(ghost),
        throwsStorage(StorageException.notFound),
      );
    });

    test('delete removes a file', () async {
      final file = await gw.createFile(
        folder,
        'gone.jpg',
        mimeType: 'image/jpeg',
      );
      await gw.deleteEntry(file);
      expect(File(file.localPath!).existsSync(), isFalse);
      expect(await gw.childByName(folder, 'gone.jpg'), isNull);
    });
  });

  group('non-local refusal', () {
    test('Io operations reject SafTree and content paths', () async {
      const tree = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'primary',
        displayName: 'DCIM',
      );
      await expectLater(
        gw.exists(tree),
        throwsStorage(StorageException.unsupported),
      );
      await expectLater(
        gw.listChildren(tree),
        throwsStorage(StorageException.unsupported),
      );

      final contentEntry = StorageEntry(
        folder: tree,
        name: 'a.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        documentId: 'primary:a.arw',
      );
      await expectLater(
        gw.readAll(contentEntry),
        throwsStorage(StorageException.unsupported),
      );

      final disguised = StorageEntry(
        folder: folder,
        name: 'a.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        localPath: 'content://auth/document/primary%3Aa.arw',
      );
      await expectLater(
        gw.readAll(disguised),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });
}
