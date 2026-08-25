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

    test('SafTree identity ignores displayName', () {
      const labeled = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'primary',
        displayName: 'DCIM',
      );
      const relabeled = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'primary',
        displayName: 'Camera',
      );
      const otherDocument = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'other',
        displayName: 'DCIM',
      );
      expect(labeled, relabeled);
      expect(labeled.hashCode, relabeled.hashCode);
      expect(labeled, isNot(otherDocument));
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

    test('StorageEntry identity ignores size and MIME', () {
      const folderA = LocalFolder('/tmp/shoot');
      const created = StorageEntry(
        folder: folderA,
        name: 'shot.arw',
        mimeType: 'image/jpeg',
        isDirectory: false,
        localPath: '/tmp/shoot/shot.arw',
        size: 0,
      );
      const listed = StorageEntry(
        folder: folderA,
        name: 'shot.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        localPath: '/tmp/shoot/shot.arw',
        size: 4096,
      );
      const otherFile = StorageEntry(
        folder: folderA,
        name: 'other.arw',
        mimeType: 'image/jpeg',
        isDirectory: false,
        localPath: '/tmp/shoot/other.arw',
        size: 0,
      );
      expect(created, listed);
      expect(created.hashCode, listed.hashCode);
      expect(created, isNot(otherFile));
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

  group('cache ownership', () {
    test('deleteCache refuses an arbitrary photo path and leaves it intact',
        () async {
      final photo = File(p.join(tmp.path, 'export.arw'));
      await photo.writeAsBytes([1, 2, 3]);

      await expectLater(
        gw.deleteCache(photo.path),
        throwsStorage(StorageException.invalidArg),
      );
      expect(photo.existsSync(), isTrue);
      expect(photo.readAsBytesSync(), [1, 2, 3]);
    });

    test('issued cache path is deletable; prefix and traversal lookalikes are refused',
        () async {
      final cacheGw = IoStorageGateway(cacheDirectory: tmp);
      final source = await cacheGw.createFile(
        folder,
        'shot.arw',
        mimeType: 'application/octet-stream',
      );
      await cacheGw.writeBytes(source, Uint8List.fromList([9, 8, 7]));
      final photo = File(p.join(tmp.path, 'export.arw'));
      await photo.writeAsBytes([4, 5]);

      final cachePath = await cacheGw.materializeToCache(source);
      expect(File(cachePath).existsSync(), isTrue);
      expect(File(cachePath).readAsBytesSync(), [9, 8, 7]);

      final prefixLookalike = File('${cachePath}_extra');
      await prefixLookalike.writeAsBytes([1]);
      final shorterPrefix = cachePath.substring(0, cachePath.length - 1);
      final traversal = p.join(cachePath, '..', 'export.arw');

      await expectLater(
        cacheGw.deleteCache(prefixLookalike.path),
        throwsStorage(StorageException.invalidArg),
      );
      expect(prefixLookalike.existsSync(), isTrue);

      await expectLater(
        cacheGw.deleteCache(shorterPrefix),
        throwsStorage(StorageException.invalidArg),
      );

      await expectLater(
        cacheGw.deleteCache(traversal),
        throwsStorage(StorageException.invalidArg),
      );
      expect(photo.existsSync(), isTrue);
      expect(photo.readAsBytesSync(), [4, 5]);

      await cacheGw.deleteCache(cachePath);
      expect(File(cachePath).existsSync(), isFalse);

      await cacheGw.deleteCache(cachePath);
      expect(File(cachePath).existsSync(), isFalse);

      await expectLater(
        cacheGw.deleteCache(photo.path),
        throwsStorage(StorageException.invalidArg),
      );
      expect(photo.existsSync(), isTrue);
    });

    test('another gateway instance cannot delete this instance\'s cache file',
        () async {
      final owner = IoStorageGateway(cacheDirectory: tmp);
      final stranger = IoStorageGateway(cacheDirectory: tmp);
      final source = await owner.createFile(
        folder,
        'shot.arw',
        mimeType: 'application/octet-stream',
      );
      await owner.writeBytes(source, Uint8List.fromList([2]));
      final cachePath = await owner.materializeToCache(source);

      await expectLater(
        stranger.deleteCache(cachePath),
        throwsStorage(StorageException.invalidArg),
      );
      expect(File(cachePath).existsSync(), isTrue);

      await owner.deleteCache(cachePath);
      expect(File(cachePath).existsSync(), isFalse);
    });
  });

  group('overwrite copy is transactional', () {
    test('overwrite copy goes through a sibling temp, not the dest path',
        () async {
      final seenDests = <String>[];
      final transactional = IoStorageGateway(
        copyTo: (source, destPath) async {
          seenDests.add(destPath);
          return source.copy(destPath);
        },
      );
      final source = await transactional.createFile(
        folder,
        'src.arw',
        mimeType: 'application/octet-stream',
      );
      await transactional.writeBytes(source, Uint8List.fromList([9, 9]));
      await transactional.createDirectory(folder, 'RAW');
      final destPath = p.join(tmp.path, 'RAW', 'src.arw');
      await File(destPath).writeAsBytes([1]);

      await transactional.copyFile(
        source,
        folder,
        'src.arw',
        destParentDocumentId: 'RAW',
        overwrite: true,
      );

      expect(seenDests, isNotEmpty);
      expect(seenDests, everyElement(isNot(destPath)));
      expect(
        seenDests,
        everyElement(predicate<String>((path) => p.dirname(path) == p.dirname(destPath))),
      );
      expect(File(destPath).readAsBytesSync(), [9, 9]);
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(_siblingNames(Directory(p.dirname(destPath))), {'src.arw'});
    });

    test('copy failure keeps the original dest and removes temps', () async {
      final failing = IoStorageGateway(
        copyTo: (source, destPath) async {
          await File(destPath).writeAsBytes([7], flush: true);
          throw const FileSystemException('copy failed');
        },
      );
      final source = await failing.createFile(
        folder,
        'src.arw',
        mimeType: 'application/octet-stream',
      );
      await failing.writeBytes(source, Uint8List.fromList([9, 9]));
      await failing.createDirectory(folder, 'RAW');
      final destDir = Directory(p.join(tmp.path, 'RAW'));
      final destFile = File(p.join(destDir.path, 'src.arw'));
      await destFile.writeAsBytes([1, 2, 3]);
      final before = _siblingNames(destDir);

      await expectLater(
        failing.copyFile(
          source,
          folder,
          'src.arw',
          destParentDocumentId: 'RAW',
          overwrite: true,
        ),
        throwsStorage(StorageException.ioFailure),
      );
      expect(destFile.readAsBytesSync(), [1, 2, 3]);
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(_siblingNames(destDir), before);
    });

    test('verification failure keeps the original dest and removes temps',
        () async {
      final failing = IoStorageGateway(
        verifyCopied: (copied, source) async {
          throw const StorageException(
            StorageException.ioFailure,
            'copy verification failed',
          );
        },
      );
      final source = await failing.createFile(
        folder,
        'src.arw',
        mimeType: 'application/octet-stream',
      );
      await failing.writeBytes(source, Uint8List.fromList([9, 9]));
      await failing.createDirectory(folder, 'RAW');
      final destDir = Directory(p.join(tmp.path, 'RAW'));
      final destFile = File(p.join(destDir.path, 'src.arw'));
      await destFile.writeAsBytes([1, 2, 3]);
      final before = _siblingNames(destDir);

      await expectLater(
        failing.copyFile(
          source,
          folder,
          'src.arw',
          destParentDocumentId: 'RAW',
          overwrite: true,
        ),
        throwsStorage(StorageException.ioFailure),
      );
      expect(destFile.readAsBytesSync(), [1, 2, 3]);
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(_siblingNames(destDir), before);
    });

    test('replacement failure keeps the original dest and removes temps',
        () async {
      final failing = IoStorageGateway(
        replaceFile: (temp, destPath) async {
          throw const FileSystemException('replace failed');
        },
      );
      final source = await failing.createFile(
        folder,
        'src.arw',
        mimeType: 'application/octet-stream',
      );
      await failing.writeBytes(source, Uint8List.fromList([9, 9]));
      await failing.createDirectory(folder, 'RAW');
      final destDir = Directory(p.join(tmp.path, 'RAW'));
      final destFile = File(p.join(destDir.path, 'src.arw'));
      await destFile.writeAsBytes([1, 2, 3]);
      final before = _siblingNames(destDir);

      await expectLater(
        failing.copyFile(
          source,
          folder,
          'src.arw',
          destParentDocumentId: 'RAW',
          overwrite: true,
        ),
        throwsStorage(StorageException.ioFailure),
      );
      expect(destFile.readAsBytesSync(), [1, 2, 3]);
      expect(File(source.localPath!).existsSync(), isTrue);
      expect(_siblingNames(destDir), before);
    });
  });

  group('bounded local materialization', () {
    test('streams via copy to a gateway-owned name and rejects traversal names',
        () async {
      var copiedViaSeam = false;
      final cacheGw = IoStorageGateway(
        cacheDirectory: tmp,
        copyTo: (source, destPath) async {
          copiedViaSeam = true;
          expect(p.basename(destPath), isNot(contains('shot.arw')));
          expect(p.basename(destPath), isNot(contains('..')));
          return source.copy(destPath);
        },
      );
      final source = await cacheGw.createFile(
        folder,
        'shot.arw',
        mimeType: 'application/octet-stream',
      );
      await cacheGw.writeBytes(source, Uint8List.fromList([3, 2, 1]));

      final cachePath = await cacheGw.materializeToCache(source);
      expect(copiedViaSeam, isTrue);
      expect(p.basename(cachePath), isNot(contains('shot.arw')));
      expect(File(cachePath).readAsBytesSync(), [3, 2, 1]);
      await cacheGw.deleteCache(cachePath);

      final traversalName = StorageEntry(
        folder: folder,
        name: '../escape.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
        localPath: source.localPath,
      );
      await expectLater(
        cacheGw.materializeToCache(traversalName),
        throwsStorage(StorageException.invalidArg),
      );

      for (final badName in ['foo/bar.arw', r'foo\bar.arw', '.', '..', 'a\x00b']) {
        final bad = StorageEntry(
          folder: folder,
          name: badName,
          mimeType: 'application/octet-stream',
          isDirectory: false,
          localPath: source.localPath,
        );
        await expectLater(
          cacheGw.materializeToCache(bad),
          throwsStorage(StorageException.invalidArg),
        );
      }
      expect(_materializeLeftovers(tmp), isEmpty);
    });

    test('failed materialize deletes the partial cache file', () async {
      final cacheGw = IoStorageGateway(
        cacheDirectory: tmp,
        verifyCopied: (copied, source) async {
          throw const StorageException(
            StorageException.ioFailure,
            'cache verification failed',
          );
        },
      );
      final source = await cacheGw.createFile(
        folder,
        'shot.arw',
        mimeType: 'application/octet-stream',
      );
      await cacheGw.writeBytes(source, Uint8List.fromList([1]));

      await expectLater(
        cacheGw.materializeToCache(source),
        throwsStorage(StorageException.ioFailure),
      );
      expect(_materializeLeftovers(tmp), isEmpty);
    });
  });

  group('local path contract', () {
    IoStorageGateway injecting(FileSystemException error) {
      return IoStorageGateway(
        injectIo: () async {
          throw error;
        },
      );
    }

    test('rejects URI schemes including file: before I/O', () async {
      for (final raw in [
        'file:///tmp/shoot',
        'FILE:///tmp/shoot',
        'sftp://host/photos',
        'data:text/plain,hi',
        'mailto:user@example.com',
      ]) {
        await expectLater(
          gw.exists(LocalFolder(raw)),
          throwsStorage(StorageException.invalidArg),
        );
      }
    });

    test('rejects drive-relative C:Photos', () async {
      await expectLater(
        gw.exists(const LocalFolder('C:Photos')),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        gw.exists(const LocalFolder('c:Photos')),
        throwsStorage(StorageException.invalidArg),
      );
    });

    test('Task 03 local shapes pass validation without constructing File first',
        () async {
      const injected = FileSystemException('injected');
      final gated = injecting(injected);

      await expectLater(
        gated.exists(const LocalFolder(r'C:\Photos')),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        gated.exists(const LocalFolder('C:/Photos')),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        gated.exists(const LocalFolder(r'\\server\share\Photos')),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        gated.exists(const LocalFolder('Photos')),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        gated.exists(folder),
        throwsStorage(StorageException.ioFailure),
      );
    });
  });

  group('typed failures', () {
    test('named design constants include SAF local codes', () {
      expect(StorageException.permissionDenied, 'permission_denied');
      expect(StorageException.readOnly, 'read_only');
      expect(StorageException.quota, 'quota');
      expect(StorageException.cancelled, 'cancelled');
    });

    test('maps FileSystemException to io_failure or quota', () async {
      final ioFail = IoStorageGateway(
        injectIo: () async {
          throw const FileSystemException('permission');
        },
      );
      final quota = IoStorageGateway(
        injectIo: () async {
          throw FileSystemException(
            'No space left on device',
            tmp.path,
            const OSError('No space left on device', 28),
          );
        },
      );
      final source = await gw.createFile(
        folder,
        'note.bin',
        mimeType: 'application/octet-stream',
      );
      await gw.writeBytes(source, Uint8List.fromList([1]));

      await expectLater(
        ioFail.createDirectory(folder, 'RAW'),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.createFile(folder, 'x.bin', mimeType: 'application/octet-stream'),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.readAll(source),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.writeBytes(source, Uint8List.fromList([2])),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.listChildren(folder),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.materializeToCache(source),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        quota.createDirectory(folder, 'RAW'),
        throwsStorage(StorageException.quota),
      );
    });

    test('maps disk-full OS errors by host platform', () async {
      Future<void> expectMapped(int osCode, String code) async {
        final gated = IoStorageGateway(
          injectIo: () async {
            throw FileSystemException(
              'disk full',
              tmp.path,
              OSError('disk full', osCode),
            );
          },
        );
        await expectLater(
          gated.createDirectory(folder, 'RAW'),
          throwsStorage(code),
        );
      }

      await expectMapped(28, StorageException.quota);
      await expectMapped(
        112,
        Platform.isWindows
            ? StorageException.quota
            : StorageException.ioFailure,
      );
    });

    test('does not swallow programming errors or StorageException', () async {
      final bug = IoStorageGateway(
        injectIo: () async {
          throw ArgumentError('programmer bug');
        },
      );
      await expectLater(
        bug.createDirectory(folder, 'RAW'),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        gw.createDirectory(folder, '..'),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });
}

Set<String> _siblingNames(Directory dir) {
  return dir.listSync().map((entity) => p.basename(entity.path)).toSet();
}

Set<String> _materializeLeftovers(Directory dir) {
  return dir
      .listSync()
      .map((entity) => p.basename(entity.path))
      .where((name) => name.startsWith('ps_mat_'))
      .toSet();
}
