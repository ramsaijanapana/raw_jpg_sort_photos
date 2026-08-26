import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';

Matcher throwsStorage(String code) => throwsA(
      isA<StorageException>().having((e) => e.code, 'code', code),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SafChannel.channelName);
  const tree = SafTree(
    treeUri:
        'content://com.android.externalstorage.documents/tree/primary%3ADCIM',
    documentId: 'primary:DCIM',
    displayName: 'DCIM',
  );

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) responder;
  late SafChannel saf;

  Map<String, Object?> args([int index = 0]) =>
      Map<String, Object?>.from(calls[index].arguments as Map);

  setUp(() {
    calls = <MethodCall>[];
    responder = (_) => null;
    saf = SafChannel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return responder(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<String, Object?> entryMap({
    String documentId = 'primary:DCIM/shot.arw',
    String displayName = 'shot.arw',
    String? mimeType = 'application/octet-stream',
    int? size = 12,
    int? lastModified = 1700000000000,
    bool? isDirectory = false,
  }) {
    return <String, Object?>{
      'documentId': documentId,
      'displayName': displayName,
      if (mimeType != null) 'mimeType': mimeType,
      if (size != null) 'size': size,
      if (lastModified != null) 'lastModified': lastModified,
      if (isDirectory != null) 'isDirectory': isDirectory,
    };
  }

  group('channel identity', () {
    test('default and injected channel names match the locked SAF channel', () {
      expect(SafChannel.channelName, 'com.photosorter.photo_sorter/saf');
      expect(SafChannel().channel.name, SafChannel.channelName);
      const injected = MethodChannel(SafChannel.channelName);
      expect(SafChannel(injected).channel.name, SafChannel.channelName);
    });
  });

  group('listChildren', () {
    test('sends treeUri and documentId exactly', () async {
      responder = (_) => <String, Object?>{'entries': <Object>[]};
      await saf.listChildren(
        treeUri: tree.treeUri,
        documentId: 'primary:DCIM/RAW',
        folder: tree,
      );
      expect(calls.single.method, 'listChildren');
      expect(args().keys, unorderedEquals(['treeUri', 'documentId']));
      expect(args()['treeUri'], tree.treeUri);
      expect(args()['documentId'], 'primary:DCIM/RAW');
    });

    test('decodes displayName to name and drops lastModified', () async {
      responder = (_) => <String, Object?>{
            'entries': <Object>[
              entryMap(
                documentId: 'primary:DCIM/shot.arw',
                displayName: 'shot.arw',
                lastModified: 99,
              ),
            ],
          };
      final entries = await saf.listChildren(
        treeUri: tree.treeUri,
        documentId: tree.documentId,
        folder: tree,
      );
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.name, 'shot.arw');
      expect(entry.documentId, 'primary:DCIM/shot.arw');
      expect(entry.localPath, isNull);
      expect(entry.folder, tree);
      expect(entry.mimeType, 'application/octet-stream');
      expect(entry.size, 12);
      expect(entry.isDirectory, isFalse);
    });

    test('missing documentId fails closed with io_failure', () async {
      responder = (_) => <String, Object?>{
            'entries': <Object>[
              <String, Object?>{
                'displayName': 'shot.arw',
                'mimeType': 'application/octet-stream',
                'isDirectory': false,
              },
            ],
          };
      await expectLater(
        saf.listChildren(
          treeUri: tree.treeUri,
          documentId: tree.documentId,
          folder: tree,
        ),
        throwsStorage(StorageException.ioFailure),
      );
    });
  });

  group('childByName', () {
    test('returns a decoded entry when present', () async {
      responder = (_) => <String, Object?>{'entry': entryMap()};
      final entry = await saf.childByName(
        treeUri: tree.treeUri,
        parentDocumentId: tree.documentId,
        name: 'shot.arw',
        folder: tree,
      );
      expect(calls.single.method, 'childByName');
      expect(
        args().keys,
        unorderedEquals(['treeUri', 'parentDocumentId', 'name']),
      );
      expect(args()['treeUri'], tree.treeUri);
      expect(args()['parentDocumentId'], tree.documentId);
      expect(args()['name'], 'shot.arw');
      expect(entry, isNotNull);
      expect(entry!.name, 'shot.arw');
      expect(entry.documentId, 'primary:DCIM/shot.arw');
      expect(entry.localPath, isNull);
    });

    test('returns null when entry is null', () async {
      responder = (_) => <String, Object?>{'entry': null};
      final entry = await saf.childByName(
        treeUri: tree.treeUri,
        parentDocumentId: tree.documentId,
        name: 'missing.arw',
        folder: tree,
      );
      expect(entry, isNull);
    });
  });

  group('createDirectory and createFile', () {
    test('createDirectory sends keys and returns the entry', () async {
      responder = (_) => <String, Object?>{
            'entry': entryMap(
              documentId: 'primary:DCIM/RAW',
              displayName: 'RAW',
              mimeType: StorageEntry.directoryMimeType,
              size: null,
              isDirectory: true,
            ),
          };
      final entry = await saf.createDirectory(
        treeUri: tree.treeUri,
        parentDocumentId: tree.documentId,
        name: 'RAW',
        folder: tree,
      );
      expect(calls.single.method, 'createDirectory');
      expect(
        args().keys,
        unorderedEquals(['treeUri', 'parentDocumentId', 'name']),
      );
      expect(args()['name'], 'RAW');
      expect(entry.isDirectory, isTrue);
      expect(entry.documentId, 'primary:DCIM/RAW');
      expect(entry.localPath, isNull);
    });

    test('createFile sends keys and returns the entry', () async {
      responder = (_) => <String, Object?>{
            'entry': entryMap(
              documentId: 'primary:DCIM/cull_session.json',
              displayName: 'cull_session.json',
              mimeType: 'application/json',
              size: 0,
            ),
          };
      final entry = await saf.createFile(
        treeUri: tree.treeUri,
        parentDocumentId: tree.documentId,
        displayName: 'cull_session.json',
        mimeType: 'application/json',
        folder: tree,
      );
      expect(calls.single.method, 'createFile');
      expect(
        args().keys,
        unorderedEquals([
          'treeUri',
          'parentDocumentId',
          'displayName',
          'mimeType',
        ]),
      );
      expect(args()['displayName'], 'cull_session.json');
      expect(args()['mimeType'], 'application/json');
      expect(entry.name, 'cull_session.json');
      expect(entry.documentId, 'primary:DCIM/cull_session.json');
    });
  });

  group('bytes', () {
    test('readRange sends ints and returns the scripted Uint8List', () async {
      final payload = Uint8List.fromList([9, 8, 7, 6]);
      responder = (_) => payload;
      final result = await saf.readRange(
        treeUri: tree.treeUri,
        documentId: 'primary:DCIM/shot.arw',
        offset: 2,
        length: 4,
      );
      expect(calls.single.method, 'readRange');
      expect(
        args().keys,
        unorderedEquals(['treeUri', 'documentId', 'offset', 'length']),
      );
      expect(args()['offset'], 2);
      expect(args()['length'], 4);
      expect(args()['offset'], isA<int>());
      expect(args()['length'], isA<int>());
      expect(result, equals(payload));
      expect(result, isA<Uint8List>());
    });

    test('readRange null payload is io_failure', () async {
      responder = (_) => null;
      await expectLater(
        saf.readRange(
          treeUri: tree.treeUri,
          documentId: 'primary:DCIM/shot.arw',
          offset: 0,
          length: 1,
        ),
        throwsStorage(StorageException.ioFailure),
      );
    });

    test('byteLength decodes size including zero', () async {
      responder = (_) => <String, Object?>{'size': 0};
      expect(
        await saf.byteLength(
          treeUri: tree.treeUri,
          documentId: 'primary:DCIM/empty.arw',
        ),
        0,
      );
      expect(calls.single.method, 'byteLength');
      expect(args().keys, unorderedEquals(['treeUri', 'documentId']));
      expect(args()['documentId'], 'primary:DCIM/empty.arw');

      responder = (_) => <String, Object?>{'size': 42};
      expect(
        await saf.byteLength(
          treeUri: tree.treeUri,
          documentId: 'primary:DCIM/shot.arw',
        ),
        42,
      );
    });

    test('writeBytes sends bytes as Uint8List', () async {
      responder = (_) => <String, Object?>{'ok': true};
      final bytes = Uint8List.fromList([1, 2, 3]);
      await saf.writeBytes(
        treeUri: tree.treeUri,
        documentId: 'primary:DCIM/cull_session.json',
        bytes: bytes,
      );
      expect(calls.single.method, 'writeBytes');
      expect(
        args().keys,
        unorderedEquals(['treeUri', 'documentId', 'bytes']),
      );
      expect(args()['bytes'], isA<Uint8List>());
      expect(args()['bytes'], equals(bytes));
    });
  });

  group('copyTo and move', () {
    test('copyTo sends overwrite and nonempty opId', () async {
      responder = (_) => <String, Object?>{
            'entry': entryMap(
              documentId: 'primary:OUT/shot.arw',
              displayName: 'shot.arw',
            ),
            'bytesCopied': 12,
          };
      const dest = SafTree(
        treeUri:
            'content://com.android.externalstorage.documents/tree/primary%3AOUT',
        documentId: 'primary:OUT',
        displayName: 'OUT',
      );
      final result = await saf.copyTo(
        srcTreeUri: tree.treeUri,
        srcDocumentId: 'primary:DCIM/shot.arw',
        destTreeUri: dest.treeUri,
        destParentId: dest.documentId,
        destName: 'shot.arw',
        overwrite: false,
        opId: 'saf_1_1',
        destFolder: dest,
      );
      expect(calls.single.method, 'copyTo');
      expect(
        args().keys,
        unorderedEquals([
          'srcTreeUri',
          'srcDocumentId',
          'destTreeUri',
          'destParentId',
          'destName',
          'overwrite',
          'opId',
        ]),
      );
      expect(args()['overwrite'], isFalse);
      expect(args()['opId'], 'saf_1_1');
      expect((args()['opId'] as String).isNotEmpty, isTrue);
      expect(result.bytesCopied, 12);
      expect(result.entry.documentId, 'primary:OUT/shot.arw');
    });

    test('move sends destName and decodes outcome', () async {
      responder = (_) => <String, Object?>{
            'outcome': 'renamed',
            'entry': entryMap(
              documentId: 'primary:DCIM/RAW/shot.arw',
              displayName: 'shot.arw',
            ),
          };
      final result = await saf.move(
        treeUri: tree.treeUri,
        documentId: 'primary:DCIM/shot.arw',
        sourceParentId: null,
        destParentId: 'primary:DCIM/RAW',
        destName: 'shot.arw',
        folder: tree,
      );
      expect(calls.single.method, 'move');
      expect(
        args().keys,
        unorderedEquals([
          'treeUri',
          'documentId',
          'sourceParentId',
          'destParentId',
          'destName',
        ]),
      );
      expect(args()['destName'], 'shot.arw');
      expect(args()['sourceParentId'], isNull);
      expect(result.outcome, 'renamed');
      expect(result.entry.documentId, 'primary:DCIM/RAW/shot.arw');
    });
  });

  group('delete, cache, and cancel', () {
    test('delete sends treeUri and documentId', () async {
      responder = (_) => <String, Object?>{'ok': true};
      await saf.delete(
        treeUri: tree.treeUri,
        documentId: 'primary:DCIM/shot.arw',
      );
      expect(calls.single.method, 'delete');
      expect(args().keys, unorderedEquals(['treeUri', 'documentId']));
      expect(args()['documentId'], 'primary:DCIM/shot.arw');
    });

    test('materializeToCache sends opId and decodes cachePath', () async {
      responder = (_) => <String, Object?>{
            'cachePath': '/cache/ps_mat_1',
            'size': 8,
          };
      final result = await saf.materializeToCache(
        treeUri: tree.treeUri,
        documentId: 'primary:DCIM/shot.arw',
        opId: 'saf_2_2',
      );
      expect(calls.single.method, 'materializeToCache');
      expect(
        args().keys,
        unorderedEquals(['treeUri', 'documentId', 'opId']),
      );
      expect(args()['opId'], 'saf_2_2');
      expect(result.cachePath, '/cache/ps_mat_1');
      expect(result.size, 8);
    });

    test('deleteCache sends cachePath', () async {
      responder = (_) => <String, Object?>{'ok': true};
      await saf.deleteCache('/cache/ps_mat_1');
      expect(calls.single.method, 'deleteCache');
      expect(args().keys, unorderedEquals(['cachePath']));
      expect(args()['cachePath'], '/cache/ps_mat_1');
    });

    test('cancel sends opId', () async {
      responder = (_) => <String, Object?>{'ok': true};
      await saf.cancel('saf_3_3');
      expect(calls.single.method, 'cancel');
      expect(args().keys, unorderedEquals(['opId']));
      expect(args()['opId'], 'saf_3_3');
    });
  });

  group('pickTree', () {
    test('decodes SafTree fields and defaults writeGranted to true', () async {
      responder = (_) => <String, Object?>{
            'treeUri': tree.treeUri,
            'documentId': tree.documentId,
            'displayName': 'Camera',
          };
      final picked = await saf.pickTree(title: 'Choose photos');
      expect(calls.single.method, 'pickTree');
      expect(args().keys, unorderedEquals(['title']));
      expect(args()['title'], 'Choose photos');
      expect(picked, isNotNull);
      expect(picked!.tree.treeUri, tree.treeUri);
      expect(picked.tree.documentId, tree.documentId);
      expect(picked.tree.displayName, 'Camera');
      expect(picked.writeGranted, isTrue);
    });

    test('honors writeGranted false when present', () async {
      responder = (_) => <String, Object?>{
            'treeUri': tree.treeUri,
            'documentId': tree.documentId,
            'displayName': 'DCIM',
            'writeGranted': false,
          };
      final picked = await saf.pickTree();
      expect(picked!.writeGranted, isFalse);
    });

    test('null handler result is Dart null', () async {
      responder = (_) => null;
      expect(await saf.pickTree(), isNull);
    });

    test('PlatformException cancel is Dart null, not StorageException',
        () async {
      responder = (_) => throw PlatformException(
            code: 'cancel',
            message: 'dismissed',
          );
      expect(await saf.pickTree(), isNull);
    });
  });

  group('persist wrappers', () {
    test('takePersistable sends treeUri', () async {
      responder = (_) => <String, Object?>{'ok': true};
      await saf.takePersistable(tree.treeUri);
      expect(calls.single.method, 'takePersistable');
      expect(args().keys, unorderedEquals(['treeUri']));
      expect(args()['treeUri'], tree.treeUri);
    });

    test('releasePersistable sends treeUri', () async {
      responder = (_) => <String, Object?>{'ok': true};
      await saf.releasePersistable(tree.treeUri);
      expect(calls.single.method, 'releasePersistable');
      expect(args().keys, unorderedEquals(['treeUri']));
      expect(args()['treeUri'], tree.treeUri);
    });

    test('persistedTrees sends an empty map', () async {
      responder = (_) => <String, Object?>{
            'trees': <Object>[
              <String, Object?>{
                'treeUri': tree.treeUri,
                'documentId': tree.documentId,
                'displayName': 'DCIM',
              },
            ],
          };
      final trees = await saf.persistedTrees();
      expect(calls.single.method, 'persistedTrees');
      expect(args().keys, isEmpty);
      expect(trees.single.treeUri, tree.treeUri);
      expect(trees.single.documentId, tree.documentId);
    });

    test('hasPersisted sends treeUri and decodes ok', () async {
      responder = (_) => <String, Object?>{'ok': false};
      expect(await saf.hasPersisted(tree.treeUri), isFalse);
      expect(calls.single.method, 'hasPersisted');
      expect(args().keys, unorderedEquals(['treeUri']));
      expect(args()['treeUri'], tree.treeUri);
    });
  });

  group('PlatformException mapping', () {
    const accepted = [
      StorageException.alreadyExists,
      StorageException.cancelled,
      StorageException.incompleteMove,
      StorageException.invalidArg,
      StorageException.ioFailure,
      StorageException.notFound,
      StorageException.permissionDenied,
      StorageException.quota,
      StorageException.readOnly,
      StorageException.unsupported,
    ];

    for (final code in accepted) {
      test('maps $code onto StorageException.$code', () async {
        responder = (_) => throw PlatformException(code: code, message: 'x');
        await expectLater(
          saf.byteLength(
            treeUri: tree.treeUri,
            documentId: 'primary:DCIM/shot.arw',
          ),
          throwsStorage(code),
        );
      });
    }

    test('not_a_tree becomes invalid_arg with platformCode', () async {
      responder = (_) => throw PlatformException(
            code: 'not_a_tree',
            message: 'bad uri',
          );
      await expectLater(
        saf.listChildren(
          treeUri: tree.treeUri,
          documentId: tree.documentId,
          folder: tree,
        ),
        throwsA(
          isA<StorageException>()
              .having((e) => e.code, 'code', StorageException.invalidArg)
              .having(
                (e) => e.details?['platformCode'],
                'platformCode',
                'not_a_tree',
              ),
        ),
      );
    });

    test('unknown code becomes io_failure with platformCode', () async {
      responder = (_) => throw PlatformException(
            code: 'weird_native',
            message: 'nope',
          );
      await expectLater(
        saf.delete(
          treeUri: tree.treeUri,
          documentId: 'primary:DCIM/shot.arw',
        ),
        throwsA(
          isA<StorageException>()
              .having((e) => e.code, 'code', StorageException.ioFailure)
              .having(
                (e) => e.details?['platformCode'],
                'platformCode',
                'weird_native',
              ),
        ),
      );
    });

    test('non-pickTree cancel becomes cancelled', () async {
      responder = (_) => throw PlatformException(
            code: 'cancel',
            message: 'stopped',
          );
      await expectLater(
        saf.cancel('saf_9_9'),
        throwsStorage(StorageException.cancelled),
      );
    });

    test('map details keys are preserved', () async {
      responder = (_) => throw PlatformException(
            code: StorageException.permissionDenied,
            message: 'denied',
            details: <String, Object?>{
              'treeUri': tree.treeUri,
              'documentId': 'primary:DCIM/shot.arw',
              'displayName': 'DCIM',
              'op': 'list',
            },
          );
      try {
        await saf.listChildren(
          treeUri: tree.treeUri,
          documentId: tree.documentId,
          folder: tree,
        );
        fail('expected StorageException');
      } on StorageException catch (e) {
        expect(e.code, StorageException.permissionDenied);
        expect(e.details?['treeUri'], tree.treeUri);
        expect(e.details?['documentId'], 'primary:DCIM/shot.arw');
        expect(e.details?['displayName'], 'DCIM');
        expect(e.details?['op'], 'list');
      }
    });

    test('non-map details become platformDetails', () async {
      responder = (_) => throw PlatformException(
            code: StorageException.ioFailure,
            message: 'boom',
            details: 'native-string',
          );
      try {
        await saf.byteLength(
          treeUri: tree.treeUri,
          documentId: 'primary:DCIM/shot.arw',
        );
        fail('expected StorageException');
      } on StorageException catch (e) {
        expect(e.details, {'platformDetails': 'native-string'});
      }
    });
  });

  group('handler teardown', () {
    test('cleared handler returns null-handler behavior', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      final result = await channel.invokeMethod<Object>(
        'listChildren',
        <String, Object?>{'treeUri': tree.treeUri},
      );
      expect(result, isNull);
    });
  });
}
