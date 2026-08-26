import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/cull_session.dart';
import 'package:photo_sorter/core/exporter.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/scanner.dart';
import 'package:photo_sorter/core/sorter.dart';
import 'package:photo_sorter/core/storage/byte_range_reader.dart';
import 'package:photo_sorter/core/storage/saf_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';

Matcher throwsStorage(String code) => throwsA(
      isA<StorageException>().having((e) => e.code, 'code', code),
    );

const _tree = SafTree(
  treeUri:
      'content://com.android.externalstorage.documents/tree/primary%3ADCIM',
  documentId: 'primary:DCIM',
  displayName: 'DCIM',
);
const _destTree = SafTree(
  treeUri:
      'content://com.android.externalstorage.documents/tree/primary%3AExport',
  documentId: 'primary:Export',
  displayName: 'Export',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SafChannel.channelName);

  late _ScriptedSafWorld world;
  late SafStorageGateway gw;

  setUp(() {
    world = _ScriptedSafWorld();
    gw = SafStorageGateway(SafChannel());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, world.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const tree = _tree;
  const destTree = _destTree;

  StorageEntry fileEntry({
    required String documentId,
    required String name,
    FolderRef folder = _tree,
    int? size,
    bool isDirectory = false,
    String? localPath,
    String mimeType = 'application/octet-stream',
  }) {
    return StorageEntry(
      folder: folder,
      name: name,
      documentId: documentId,
      localPath: localPath,
      mimeType: mimeType,
      size: size,
      isDirectory: isDirectory,
    );
  }

  List<MethodCall> of(String method) =>
      world.calls.where((c) => c.method == method).toList();

  Map<String, Object?> argsOf(MethodCall call) =>
      Map<String, Object?>.from(call.arguments as Map);

  group('refusal and validation', () {
    test('LocalFolder I/O is unsupported', () async {
      const local = LocalFolder('/tmp/shoot');
      await expectLater(gw.exists(local), throwsStorage(StorageException.unsupported));
      await expectLater(
        gw.listChildren(local),
        throwsStorage(StorageException.unsupported),
      );
      final localFile = fileEntry(
        documentId: 'x',
        name: 'a.arw',
        folder: local,
      );
      await expectLater(
        gw.readAll(localFile),
        throwsStorage(StorageException.unsupported),
      );
    });

    test('non-content scheme, empty ids, and NUL are invalid_arg', () async {
      await expectLater(
        gw.exists(
          const SafTree(
            treeUri: 'file:///tmp',
            documentId: 'x',
            displayName: 'tmp',
          ),
        ),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        gw.exists(
          const SafTree(
            treeUri: 'content://auth/tree/primary',
            documentId: '',
            displayName: 'DCIM',
          ),
        ),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        gw.exists(
          const SafTree(
            treeUri: 'content://auth/tree/pri\x00mary',
            documentId: 'primary',
            displayName: 'DCIM',
          ),
        ),
        throwsStorage(StorageException.invalidArg),
      );
    });

    test('file operations without documentId are invalid_arg', () async {
      world.addTree(tree);
      final missing = fileEntry(documentId: '', name: 'shot.arw');
      final nul = fileEntry(documentId: 'pri\x00mary', name: 'shot.arw');
      final unnamed = StorageEntry(
        folder: tree,
        name: 'shot.arw',
        mimeType: 'application/octet-stream',
        isDirectory: false,
      );
      await expectLater(
        gw.byteLength(missing),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        gw.byteLength(nul),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        gw.readAll(unnamed),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });

  group('exists', () {
    test('empty tree list success is true', () async {
      world.addTree(tree);
      expect(await gw.exists(tree), isTrue);
      expect(of('listChildren'), isNotEmpty);
    });

    test('not_found is false', () async {
      world.addTree(tree, listError: StorageException.notFound);
      expect(await gw.exists(tree), isFalse);
    });

    test('permission_denied is rethrown', () async {
      world.addTree(tree, listError: StorageException.permissionDenied);
      await expectLater(
        gw.exists(tree),
        throwsStorage(StorageException.permissionDenied),
      );
    });
  });

  group('list, lookup, and create', () {
    test('listChildren sorts by name', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/z.arw',
        name: 'z.arw',
        bytes: Uint8List(1),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/a.arw',
        name: 'a.arw',
        bytes: Uint8List(1),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/m.arw',
        name: 'm.arw',
        bytes: Uint8List(1),
      );
      final names =
          (await gw.listChildren(tree)).map((e) => e.name).toList();
      expect(names, ['a.arw', 'm.arw', 'z.arw']);
    });

    test('parent resolve RAW sends the opaque document id', () async {
      world.addTree(tree);
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/RAW',
        name: 'RAW',
      );
      world.calls.clear();
      await gw.listChildren(tree, childDocumentId: 'RAW');
      final listed = of('listChildren').single;
      expect(argsOf(listed)['documentId'], 'primary:DCIM/RAW');
      expect(argsOf(listed)['documentId'], isNot('RAW'));
      expect(argsOf(listed)['treeUri'], tree.treeUri);
    });

    test('childByName missing is null', () async {
      world.addTree(tree);
      expect(await gw.childByName(tree, 'nope.arw'), isNull);
    });

    test('createDirectory collision is already_exists', () async {
      world.addTree(tree);
      await gw.createDirectory(tree, 'RAW');
      await expectLater(
        gw.createDirectory(tree, 'RAW'),
        throwsStorage(StorageException.alreadyExists),
      );
    });
  });

  group('read, range, length, and write', () {
    test('readRange negative is invalid_arg as a Future', () async {
      world.addTree(tree);
      final file = fileEntry(
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
      );
      final future = gw.readRange(file, offset: -1, length: 1);
      expect(future, isA<Future<Uint8List>>());
      await expectLater(future, throwsStorage(StorageException.invalidArg));
      expect(of('readRange'), isEmpty);
      expect(of('byteLength'), isEmpty);
    });

    test('readRange zero length and empty file return empty bytes', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/empty.arw',
        name: 'empty.arw',
        bytes: Uint8List(0),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final empty = fileEntry(
        documentId: 'primary:DCIM/empty.arw',
        name: 'empty.arw',
      );
      final shot = fileEntry(
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
      );
      world.calls.clear();
      expect(await gw.readRange(empty, offset: 0, length: 4), Uint8List(0));
      expect(of('byteLength'), hasLength(1));
      expect(of('readRange'), isEmpty);

      world.calls.clear();
      expect(await gw.readRange(shot, offset: 0, length: 0), Uint8List(0));
      expect(of('byteLength'), hasLength(1));
      expect(of('readRange'), isEmpty);
    });

    test('readAll composes one byteLength and one readRange(0, size)', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
        bytes: Uint8List.fromList([4, 5, 6, 7]),
      );
      final file = fileEntry(
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
      );
      world.calls.clear();
      expect(await gw.readAll(file), Uint8List.fromList([4, 5, 6, 7]));
      expect(of('byteLength'), hasLength(1));
      expect(of('readRange'), hasLength(1));
      expect(argsOf(of('readRange').single)['offset'], 0);
      expect(argsOf(of('readRange').single)['length'], 4);
    });

    test('byteLength zero is success', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/empty.arw',
        name: 'empty.arw',
        bytes: Uint8List(0),
      );
      expect(
        await gw.byteLength(
          fileEntry(documentId: 'primary:DCIM/empty.arw', name: 'empty.arw'),
        ),
        0,
      );
    });
  });

  group('copy and move', () {
    test('copyFile overwrite false refuses an existing dest', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/src.arw',
        name: 'src.arw',
        bytes: Uint8List.fromList([1, 2]),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/dest.arw',
        name: 'dest.arw',
        bytes: Uint8List.fromList([9]),
      );
      await expectLater(
        gw.copyFile(
          fileEntry(documentId: 'primary:DCIM/src.arw', name: 'src.arw'),
          tree,
          'dest.arw',
          overwrite: false,
        ),
        throwsStorage(StorageException.alreadyExists),
      );
      expect(
        world.node(tree.treeUri, 'primary:DCIM/src.arw')!.bytes,
        Uint8List.fromList([1, 2]),
      );
      expect(
        world.node(tree.treeUri, 'primary:DCIM/dest.arw')!.bytes,
        Uint8List.fromList([9]),
      );
    });

    test('copyFile overwrite true replaces dest and keeps source', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/src.arw',
        name: 'src.arw',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/dest.arw',
        name: 'dest.arw',
        bytes: Uint8List.fromList([9, 9]),
      );
      await gw.copyFile(
        fileEntry(documentId: 'primary:DCIM/src.arw', name: 'src.arw'),
        tree,
        'dest.arw',
        overwrite: true,
      );
      expect(
        world.node(tree.treeUri, 'primary:DCIM/src.arw')!.bytes,
        Uint8List.fromList([1, 2, 3]),
      );
      expect(
        world.node(tree.treeUri, 'primary:DCIM/dest.arw')!.bytes,
        Uint8List.fromList([1, 2, 3]),
      );
      expect(argsOf(of('copyTo').single)['overwrite'], isTrue);
      expect((argsOf(of('copyTo').single)['opId'] as String).isNotEmpty, isTrue);
    });

    test('moveFile renamed and copiedAndDeleted return those enums', () async {
      world.addTree(tree);
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/RAW',
        name: 'RAW',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/pic.arw',
        name: 'pic.arw',
        bytes: Uint8List.fromList([7, 8]),
      );
      world.forcedMoveOutcome = 'renamed';
      expect(
        await gw.moveFile(
          fileEntry(documentId: 'primary:DCIM/pic.arw', name: 'pic.arw'),
          tree,
          'pic.arw',
          destParentDocumentId: 'RAW',
        ),
        MoveOutcome.renamed,
      );

      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/other.arw',
        name: 'other.arw',
        bytes: Uint8List.fromList([1]),
      );
      world.forcedMoveOutcome = 'copiedAndDeleted';
      expect(
        await gw.moveFile(
          fileEntry(documentId: 'primary:DCIM/other.arw', name: 'other.arw'),
          tree,
          'other.arw',
          destParentDocumentId: 'RAW',
        ),
        MoveOutcome.copiedAndDeleted,
      );
    });

    test('same-tree copiedSourceRemains is incomplete_move', () async {
      world.addTree(tree);
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/RAW',
        name: 'RAW',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/pic.arw',
        name: 'pic.arw',
        bytes: Uint8List.fromList([1]),
      );
      world.forcedMoveOutcome = 'copiedSourceRemains';
      await expectLater(
        gw.moveFile(
          fileEntry(documentId: 'primary:DCIM/pic.arw', name: 'pic.arw'),
          tree,
          'pic.arw',
          destParentDocumentId: 'RAW',
        ),
        throwsStorage(StorageException.incompleteMove),
      );
    });

    test('cross-tree copiedSourceRemains returns the enum', () async {
      world.addTree(tree);
      world.addTree(destTree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/pic.arw',
        name: 'pic.arw',
        bytes: Uint8List.fromList([1]),
      );
      world.forcedMoveOutcome = 'copiedSourceRemains';
      expect(
        await gw.moveFile(
          fileEntry(documentId: 'primary:DCIM/pic.arw', name: 'pic.arw'),
          destTree,
          'pic.arw',
        ),
        MoveOutcome.copiedSourceRemains,
      );
    });

    test('missing move outcome is invalid_arg', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/pic.arw',
        name: 'pic.arw',
        bytes: Uint8List.fromList([1]),
      );
      world.omitMoveOutcome = true;
      await expectLater(
        gw.moveFile(
          fileEntry(documentId: 'primary:DCIM/pic.arw', name: 'pic.arw'),
          tree,
          'pic.arw',
        ),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });

  group('isSameFolder', () {
    test('normalizes URI authority case and refuses two LocalFolders', () async {
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
      expect(await gw.isSameFolder(a, const LocalFolder('/tmp/shoot')), isFalse);
      await expectLater(
        gw.isSameFolder(
          const LocalFolder('/tmp/a'),
          const LocalFolder('/tmp/b'),
        ),
        throwsStorage(StorageException.unsupported),
      );
    });
  });

  group('cache ownership', () {
    test('issued path deletes; foreign and retired paths stay local-only',
        () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
        bytes: Uint8List.fromList([9, 8, 7]),
      );
      final file = fileEntry(
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
      );
      final cachePath = await gw.materializeToCache(file);
      expect(cachePath, isNotEmpty);
      expect(of('materializeToCache'), hasLength(1));
      expect(
        (argsOf(of('materializeToCache').single)['opId'] as String).isNotEmpty,
        isTrue,
      );

      await expectLater(
        gw.deleteCache('/not/issued/cache'),
        throwsStorage(StorageException.invalidArg),
      );
      expect(of('deleteCache'), isEmpty);

      await gw.deleteCache(cachePath);
      expect(of('deleteCache'), hasLength(1));
      expect(argsOf(of('deleteCache').single)['cachePath'], cachePath);

      world.calls.clear();
      await gw.deleteCache(cachePath);
      expect(of('deleteCache'), isEmpty);

      await expectLater(
        gw.deleteCache('/still/foreign'),
        throwsStorage(StorageException.invalidArg),
      );
      expect(of('deleteCache'), isEmpty);
    });

    test('directory materialize is invalid_arg', () async {
      world.addTree(tree);
      await expectLater(
        gw.materializeToCache(
          fileEntry(
            documentId: 'primary:DCIM/RAW',
            name: 'RAW',
            isDirectory: true,
            mimeType: StorageEntry.directoryMimeType,
          ),
        ),
        throwsStorage(StorageException.invalidArg),
      );
      expect(of('materializeToCache'), isEmpty);
    });
  });

  group('GatewayByteRangeReader', () {
    test('length and read hit byteLength and readRange', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
        bytes: Uint8List.fromList([10, 11, 12]),
      );
      final file = fileEntry(
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
      );
      final reader = GatewayByteRangeReader(gw, file);
      world.calls.clear();
      expect(await reader.length(), 3);
      expect(await reader.read(1, 2), Uint8List.fromList([11, 12]));
      expect(of('byteLength'), isNotEmpty);
      expect(of('readRange'), isNotEmpty);
    });
  });

  group('engine integration', () {
    void seedShoot() {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/root.cr2',
        name: 'root.cr2',
        bytes: Uint8List.fromList([1]),
        mime: 'application/octet-stream',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/root.jpg',
        name: 'root.jpg',
        bytes: Uint8List.fromList([2]),
      );
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/RAW',
        name: 'RAW',
      );
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/JPG',
        name: 'JPG',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: 'primary:DCIM/RAW',
        documentId: 'primary:DCIM/RAW/sub.arw',
        name: 'sub.arw',
        bytes: Uint8List.fromList([3]),
        mime: 'application/octet-stream',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: 'primary:DCIM/JPG',
        documentId: 'primary:DCIM/JPG/sub.JPG',
        name: 'sub.JPG',
        bytes: Uint8List.fromList([4]),
      );
    }

    test('scanRaws and scanPairs use opaque ids and no File', () async {
      seedShoot();
      final raws = await scanRaws(tree, gateway: gw);
      expect(raws.map((e) => e.name), containsAll(['root.cr2', 'sub.arw']));
      final sub = raws.firstWhere((e) => e.name == 'sub.arw');
      expect(sub.documentId, 'primary:DCIM/RAW/sub.arw');
      expect(sub.documentId, isNot('RAW'));
      expect(sub.localPath, isNull);
      expect(sub.folder, tree);
      expect(sub, isNot(isA<File>()));

      final listRaw = of('listChildren').where((c) {
        return argsOf(c)['documentId'] == 'primary:DCIM/RAW';
      });
      expect(listRaw, isNotEmpty);
      expect(
        of('childByName').any((c) => argsOf(c)['name'] == 'RAW'),
        isTrue,
      );

      final pairs = await scanPairs(tree, gateway: gw);
      expect(pairs.map((p) => p.stem), containsAll(['root', 'sub']));
      final rootPair = pairs.firstWhere((p) => p.stem == 'root');
      final subPair = pairs.firstWhere((p) => p.stem == 'sub');
      expect(rootPair.jpg?.name, 'root.jpg');
      expect(subPair.jpg?.name, 'sub.JPG');
      expect(subPair.jpg?.documentId, 'primary:DCIM/JPG/sub.JPG');
    });

    test('in-place sort moves sources into RAW/JPG', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1, 2]),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/photo.jpg',
        name: 'photo.jpg',
        bytes: Uint8List.fromList([3]),
      );
      final result = await sortPhotos(
        input: tree,
        output: tree,
        gateway: gw,
      );
      expect(result.moved, isTrue);
      expect(result.outputPath, '');
      expect(result.rawCount, 1);
      expect(result.jpgCount, 1);
      final rootNames =
          (await gw.listChildren(tree)).map((e) => e.name).toList();
      expect(rootNames, isNot(contains('photo.arw')));
      expect(rootNames, isNot(contains('photo.jpg')));
      expect(
        await gw.childByName(tree, 'photo.arw', parentDocumentId: 'RAW'),
        isNotNull,
      );
      expect(
        await gw.childByName(tree, 'photo.jpg', parentDocumentId: 'JPG'),
        isNotNull,
      );
    });

    test('dest-exists skip leaves dest bytes unchanged', () async {
      world.addTree(tree);
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/RAW',
        name: 'RAW',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: 'primary:DCIM/RAW',
        documentId: 'primary:DCIM/RAW/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([9, 9, 9]),
      );
      final result = await sortPhotos(
        input: tree,
        output: tree,
        gateway: gw,
      );
      expect(result.skipped, 1);
      expect(result.rawCount, 0);
      expect(
        world.node(tree.treeUri, 'primary:DCIM/RAW/photo.arw')!.bytes,
        Uint8List.fromList([9, 9, 9]),
      );
    });

    test('cross-tree copy keeps source and reports moved false', () async {
      world.addTree(tree);
      world.addTree(destTree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([5]),
      );
      final result = await sortPhotos(
        input: tree,
        output: destTree,
        gateway: gw,
      );
      expect(result.moved, isFalse);
      expect(result.rawCount, 1);
      expect(world.node(tree.treeUri, 'primary:DCIM/photo.arw'), isNotNull);
      expect(
        argsOf(of('copyTo').single)['overwrite'],
        isFalse,
      );
      final destChild = await gw.childByName(
        destTree,
        'photo.arw',
        parentDocumentId: 'RAW',
      );
      expect(destChild, isNotNull);
    });

    test('immediate shouldCancel is cancelled with 0 processed', () async {
      world.addTree(tree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/a.arw',
        name: 'a.arw',
        bytes: Uint8List.fromList([1]),
      );
      final result = await sortPhotos(
        input: tree,
        output: tree,
        gateway: gw,
        shouldCancel: () => true,
      );
      expect(result.cancelled, isTrue);
      expect(result.rawCount + result.jpgCount + result.skipped, 0);
    });

    test('export exact id plus decoy does not copy the missing document',
        () async {
      world.addTree(tree);
      world.addTree(destTree);
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/RAW',
        name: 'RAW',
      );
      world.seedDir(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/JPG',
        name: 'JPG',
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/decoy.arw',
        name: 'gone.arw',
        bytes: Uint8List.fromList([8]),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: 'primary:DCIM/RAW',
        documentId: 'primary:DCIM/RAW/decoy.arw',
        name: 'gone.arw',
        bytes: Uint8List.fromList([8]),
      );
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: 'primary:DCIM/JPG',
        documentId: 'primary:DCIM/JPG/decoy.arw',
        name: 'gone.arw',
        bytes: Uint8List.fromList([8]),
      );
      world.vanish('primary:DCIM/missing.arw');
      final pair = PhotoPair(
        stem: 'gone',
        raw: fileEntry(
          documentId: 'primary:DCIM/missing.arw',
          name: 'gone.arw',
        ),
      );
      world.calls.clear();
      final result = await exportKept(
        source: tree,
        destination: destTree,
        gateway: gw,
        pairs: [pair],
        session: CullSession({'gone': CullFlag.keep}),
        includeJpgs: false,
      );
      expect(result.copied, 0);
      expect(
        of('copyTo').where((c) {
          return argsOf(c)['srcDocumentId'] == 'primary:DCIM/missing.arw';
        }),
        isEmpty,
      );
    });

    test('export copies a zero-byte source', () async {
      world.addTree(tree);
      world.addTree(destTree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/empty.arw',
        name: 'empty.arw',
        bytes: Uint8List(0),
      );
      final pair = PhotoPair(
        stem: 'empty',
        raw: fileEntry(
          documentId: 'primary:DCIM/empty.arw',
          name: 'empty.arw',
          size: 0,
        ),
      );
      final result = await exportKept(
        source: tree,
        destination: destTree,
        gateway: gw,
        pairs: [pair],
        session: CullSession({'empty': CullFlag.keep}),
        includeJpgs: false,
      );
      expect(result.copied, 1);
      final dest = await gw.childByName(destTree, 'empty.arw');
      expect(dest, isNotNull);
      expect(await gw.byteLength(dest!), 0);
    });

    test('export overwrite replaces dest bytes', () async {
      world.addTree(tree);
      world.addTree(destTree);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/shot.arw',
        name: 'shot.arw',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      world.seedFile(
        treeUri: destTree.treeUri,
        parentId: destTree.documentId,
        documentId: 'primary:Export/shot.arw',
        name: 'shot.arw',
        bytes: Uint8List.fromList([9, 9]),
      );
      final result = await exportKept(
        source: tree,
        destination: destTree,
        gateway: gw,
        pairs: [
          PhotoPair(
            stem: 'shot',
            raw: fileEntry(
              documentId: 'primary:DCIM/shot.arw',
              name: 'shot.arw',
            ),
          ),
        ],
        session: CullSession({'shot': CullFlag.keep}),
        includeJpgs: false,
      );
      expect(result.copied, 1);
      expect(argsOf(of('copyTo').single)['overwrite'], isTrue);
      expect(
        world.node(destTree.treeUri, 'primary:Export/shot.arw')!.bytes,
        Uint8List.fromList([1, 2, 3]),
      );
    });

    test('session save and load round-trip keep/skip JSON', () async {
      world.addTree(tree);
      final session = CullSession({
        'IMG_001': CullFlag.keep,
        'IMG_002': CullFlag.skip,
      });
      await session.save(tree, gateway: gw);
      final loaded = await CullSession.load(tree, gateway: gw);
      expect(loaded.flagFor('IMG_001'), CullFlag.keep);
      expect(loaded.flagFor('IMG_002'), CullFlag.skip);
      final file = await gw.childByName(tree, cullSessionFileName);
      expect(file, isNotNull);
      final text = utf8.decode(await gw.readAll(file!));
      expect(jsonDecode(text), {'IMG_001': 'keep', 'IMG_002': 'skip'});
    });

    test('session load missing or corrupt is empty and does not throw',
        () async {
      world.addTree(tree);
      expect((await CullSession.load(tree, gateway: gw)).flags, isEmpty);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/cull_session.json',
        name: cullSessionFileName,
        bytes: utf8.encode('{ this is not valid json }'),
        mime: 'application/json',
      );
      expect((await CullSession.load(tree, gateway: gw)).flags, isEmpty);
    });

    test('session save swallows read_only', () async {
      world.addTree(tree);
      world.failWrites = true;
      final session = CullSession({'IMG_001': CullFlag.keep});
      await expectLater(session.save(tree, gateway: gw), completes);
    });

    test('missing dest tree is invalid_arg from sort and export', () async {
      world.addTree(tree);
      world.addTree(destTree, listError: StorageException.notFound);
      world.seedFile(
        treeUri: tree.treeUri,
        parentId: tree.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1]),
      );
      await expectLater(
        sortPhotos(input: tree, output: destTree, gateway: gw),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        exportKept(
          source: tree,
          destination: destTree,
          gateway: gw,
          pairs: [
            PhotoPair(
              stem: 'photo',
              raw: fileEntry(
                documentId: 'primary:DCIM/photo.arw',
                name: 'photo.arw',
              ),
            ),
          ],
          session: CullSession({'photo': CullFlag.keep}),
          includeJpgs: false,
        ),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });
}

class _SafNode {
  _SafNode({
    required this.documentId,
    required this.parentId,
    required this.name,
    required this.mime,
    required this.isDirectory,
    Uint8List? bytes,
  }) : bytes = bytes ?? Uint8List(0);

  String documentId;
  String? parentId;
  String name;
  String mime;
  bool isDirectory;
  Uint8List bytes;
}

class _TreeState {
  _TreeState(this.treeUri, this.rootId);

  final String treeUri;
  final String rootId;
  final Map<String, _SafNode> nodes = <String, _SafNode>{};
  String? listError;
}

class _ScriptedSafWorld {
  final Map<String, _TreeState> trees = <String, _TreeState>{};
  final List<MethodCall> calls = <MethodCall>[];
  final Set<String> vanished = <String>{};
  final Set<String> cachePaths = <String>{};
  String? forcedMoveOutcome;
  bool omitMoveOutcome = false;
  bool failWrites = false;
  int _seq = 0;

  SafTree addTree(SafTree tree, {String? listError}) {
    final state = _TreeState(tree.treeUri, tree.documentId);
    state.listError = listError;
    state.nodes[tree.documentId] = _SafNode(
      documentId: tree.documentId,
      parentId: null,
      name: tree.displayName,
      mime: StorageEntry.directoryMimeType,
      isDirectory: true,
    );
    trees[tree.treeUri] = state;
    return tree;
  }

  void seedDir({
    required String treeUri,
    required String parentId,
    required String documentId,
    required String name,
  }) {
    trees[treeUri]!.nodes[documentId] = _SafNode(
      documentId: documentId,
      parentId: parentId,
      name: name,
      mime: StorageEntry.directoryMimeType,
      isDirectory: true,
    );
  }

  void seedFile({
    required String treeUri,
    required String parentId,
    required String documentId,
    required String name,
    required Uint8List bytes,
    String mime = 'application/octet-stream',
  }) {
    trees[treeUri]!.nodes[documentId] = _SafNode(
      documentId: documentId,
      parentId: parentId,
      name: name,
      mime: mime,
      isDirectory: false,
      bytes: bytes,
    );
  }

  void vanish(String documentId) {
    vanished.add(documentId);
  }

  _SafNode? node(String treeUri, String documentId) {
    return trees[treeUri]?.nodes[documentId];
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    return _dispatch(call);
  }

  Object? _dispatch(MethodCall call) {
    final args = Map<String, Object?>.from(call.arguments as Map);
    switch (call.method) {
      case 'listChildren':
        return _listChildren(args);
      case 'childByName':
        return _childByName(args);
      case 'createDirectory':
        return _createDirectory(args);
      case 'createFile':
        return _createFile(args);
      case 'readRange':
        return _readRange(args);
      case 'byteLength':
        return _byteLength(args);
      case 'writeBytes':
        return _writeBytes(args);
      case 'copyTo':
        return _copyTo(args);
      case 'move':
        return _move(args);
      case 'delete':
        return _delete(args);
      case 'materializeToCache':
        return _materialize(args);
      case 'deleteCache':
        return _deleteCache(args);
      default:
        throw PlatformException(code: 'io_failure', message: call.method);
    }
  }

  _TreeState _tree(String? treeUri) {
    final state = trees[treeUri];
    if (state == null) {
      throw PlatformException(
        code: StorageException.notFound,
        message: 'tree not found',
      );
    }
    return state;
  }

  Never _throw(String code, String message) {
    throw PlatformException(code: code, message: message);
  }

  _SafNode? _childNamed(_TreeState state, String parentId, String name) {
    for (final node in state.nodes.values) {
      if (node.parentId == parentId && node.name == name) {
        return node;
      }
    }
    return null;
  }

  Map<String, Object?> _encode(_SafNode node) {
    return <String, Object?>{
      'documentId': node.documentId,
      'displayName': node.name,
      'mimeType': node.mime,
      'size': node.isDirectory ? null : node.bytes.length,
      'lastModified': 1,
      'isDirectory': node.isDirectory,
    };
  }

  Object _listChildren(Map<String, Object?> args) {
    final state = _tree(args['treeUri'] as String?);
    if (state.listError != null) {
      _throw(state.listError!, 'list failed');
    }
    final documentId = args['documentId'] as String;
    if (!state.nodes.containsKey(documentId)) {
      _throw(StorageException.notFound, 'folder not found');
    }
    final entries = <Map<String, Object?>>[];
    for (final node in state.nodes.values) {
      if (node.parentId == documentId) {
        entries.add(_encode(node));
      }
    }
    return <String, Object?>{'entries': entries};
  }

  Object _childByName(Map<String, Object?> args) {
    final state = _tree(args['treeUri'] as String?);
    if (state.listError != null) {
      _throw(state.listError!, 'lookup failed');
    }
    final parentId = args['parentDocumentId'] as String;
    if (!state.nodes.containsKey(parentId)) {
      return <String, Object?>{'entry': null};
    }
    final child = _childNamed(state, parentId, args['name'] as String);
    return <String, Object?>{'entry': child == null ? null : _encode(child)};
  }

  Object _createDirectory(Map<String, Object?> args) {
    if (failWrites) {
      _throw(StorageException.readOnly, 'read only');
    }
    final state = _tree(args['treeUri'] as String?);
    final parentId = args['parentDocumentId'] as String;
    final name = args['name'] as String;
    final parent = state.nodes[parentId];
    if (parent == null || !parent.isDirectory) {
      _throw(StorageException.notFound, 'parent folder not found');
    }
    if (_childNamed(state, parentId, name) != null) {
      _throw(StorageException.alreadyExists, 'directory already exists');
    }
    final id = '$parentId/$name';
    final node = _SafNode(
      documentId: id,
      parentId: parentId,
      name: name,
      mime: StorageEntry.directoryMimeType,
      isDirectory: true,
    );
    state.nodes[id] = node;
    return <String, Object?>{'entry': _encode(node)};
  }

  Object _createFile(Map<String, Object?> args) {
    if (failWrites) {
      _throw(StorageException.readOnly, 'read only');
    }
    final state = _tree(args['treeUri'] as String?);
    final parentId = args['parentDocumentId'] as String;
    final name = args['displayName'] as String;
    final parent = state.nodes[parentId];
    if (parent == null || !parent.isDirectory) {
      _throw(StorageException.notFound, 'parent folder not found');
    }
    if (_childNamed(state, parentId, name) != null) {
      _throw(StorageException.alreadyExists, 'file already exists');
    }
    final id = '$parentId/$name';
    final node = _SafNode(
      documentId: id,
      parentId: parentId,
      name: name,
      mime: args['mimeType'] as String? ?? 'application/octet-stream',
      isDirectory: false,
    );
    state.nodes[id] = node;
    return <String, Object?>{'entry': _encode(node)};
  }

  Object _readRange(Map<String, Object?> args) {
    final node = _requireFile(args['treeUri'] as String?, args['documentId'] as String);
    final offset = args['offset'] as int;
    final length = args['length'] as int;
    if (offset > node.bytes.length) {
      _throw(StorageException.invalidArg, 'offset is past the end of the file');
    }
    if (length == 0 || offset == node.bytes.length) {
      return Uint8List(0);
    }
    final end = offset + length > node.bytes.length
        ? node.bytes.length
        : offset + length;
    return Uint8List.fromList(node.bytes.sublist(offset, end));
  }

  Object _byteLength(Map<String, Object?> args) {
    final node = _requireFile(args['treeUri'] as String?, args['documentId'] as String);
    return <String, Object?>{'size': node.bytes.length};
  }

  Object _writeBytes(Map<String, Object?> args) {
    if (failWrites) {
      _throw(StorageException.readOnly, 'read only');
    }
    final node = _requireFile(args['treeUri'] as String?, args['documentId'] as String);
    final bytes = args['bytes'];
    if (bytes is! Uint8List) {
      _throw(StorageException.ioFailure, 'bytes must be Uint8List');
    }
    node.bytes = bytes;
    return <String, Object?>{'ok': true};
  }

  Object _copyTo(Map<String, Object?> args) {
    final src = _requireFile(
      args['srcTreeUri'] as String?,
      args['srcDocumentId'] as String,
    );
    final destState = _tree(args['destTreeUri'] as String?);
    final destParentId = args['destParentId'] as String;
    final destName = args['destName'] as String;
    final overwrite = args['overwrite'] as bool;
    final destParent = destState.nodes[destParentId];
    if (destParent == null || !destParent.isDirectory) {
      _throw(StorageException.notFound, 'destination folder not found');
    }
    final existing = _childNamed(destState, destParentId, destName);
    if (existing != null && !overwrite) {
      _throw(StorageException.alreadyExists, 'destination exists');
    }
    if (existing != null) {
      if (existing.isDirectory) {
        _throw(StorageException.alreadyExists, 'destination is a directory');
      }
      existing.bytes = Uint8List.fromList(src.bytes);
      existing.mime = src.mime;
      return <String, Object?>{
        'entry': _encode(existing),
        'bytesCopied': src.bytes.length,
      };
    }
    final id = '$destParentId/$destName';
    final copied = _SafNode(
      documentId: id,
      parentId: destParentId,
      name: destName,
      mime: src.mime,
      isDirectory: false,
      bytes: Uint8List.fromList(src.bytes),
    );
    destState.nodes[id] = copied;
    return <String, Object?>{
      'entry': _encode(copied),
      'bytesCopied': src.bytes.length,
    };
  }

  Object _move(Map<String, Object?> args) {
    final state = _tree(args['treeUri'] as String?);
    final src = _requireFile(args['treeUri'] as String?, args['documentId'] as String);
    final destParentId = args['destParentId'] as String;
    final destName = args['destName'] as String;
    if (omitMoveOutcome) {
      return <String, Object?>{'entry': _encode(src)};
    }
    if (forcedMoveOutcome == 'copiedSourceRemains') {
      return <String, Object?>{
        'outcome': 'copiedSourceRemains',
        'entry': _encode(src),
      };
    }
    final destParent = state.nodes[destParentId];
    if (destParent == null || !destParent.isDirectory) {
      _throw(StorageException.notFound, 'destination folder not found');
    }
    if (_childNamed(state, destParentId, destName) != null) {
      _throw(StorageException.alreadyExists, 'destination exists');
    }
    src.parentId = destParentId;
    src.name = destName;
    final outcome = forcedMoveOutcome ?? 'renamed';
    return <String, Object?>{
      'outcome': outcome,
      'entry': _encode(src),
    };
  }

  Object _delete(Map<String, Object?> args) {
    final state = _tree(args['treeUri'] as String?);
    final documentId = args['documentId'] as String;
    if (!state.nodes.containsKey(documentId)) {
      _throw(StorageException.notFound, 'not found');
    }
    state.nodes.remove(documentId);
    return <String, Object?>{'ok': true};
  }

  Object _materialize(Map<String, Object?> args) {
    final node = _requireFile(args['treeUri'] as String?, args['documentId'] as String);
    _seq += 1;
    final cachePath = '/cache/saf_mat_$_seq';
    cachePaths.add(cachePath);
    return <String, Object?>{
      'cachePath': cachePath,
      'size': node.bytes.length,
    };
  }

  Object _deleteCache(Map<String, Object?> args) {
    final cachePath = args['cachePath'] as String;
    cachePaths.remove(cachePath);
    return <String, Object?>{'ok': true};
  }

  _SafNode _requireFile(String? treeUri, String documentId) {
    if (vanished.contains(documentId)) {
      _throw(StorageException.notFound, 'file not found');
    }
    final state = _tree(treeUri);
    final node = state.nodes[documentId];
    if (node == null || node.isDirectory) {
      _throw(StorageException.notFound, 'file not found');
    }
    return node;
  }
}
