import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';
import 'package:photo_sorter/core/storage/saf_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';
import 'package:photo_sorter/state/cull_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _treeUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
const _tree = SafTree(
  treeUri: _treeUri,
  documentId: 'primary:DCIM',
  displayName: 'DCIM',
);
const _dest = SafTree(
  treeUri:
      'content://com.android.externalstorage.documents/tree/primary%3AExport',
  documentId: 'primary:Export',
  displayName: 'Export',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SafChannel.channelName);
  late _ScriptedSaf harness;

  setUp(() {
    harness = _ScriptedSaf();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, harness.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<ProviderContainer> makeContainer([
    Map<String, Object> prefs = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(prefs);
    return ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(
          PrefsService(await SharedPreferences.getInstance()),
        ),
      ],
    );
  }

  void seedShoot() {
    harness.addTree(_tree);
    harness.seedFile(
      treeUri: _tree.treeUri,
      parentId: _tree.documentId,
      documentId: 'primary:DCIM/photo.arw',
      name: 'photo.arw',
      bytes: Uint8List.fromList([9, 8, 7]),
    );
  }

  test(
    'openRef(SafTree) constructs SafStorageGateway and scans via document ids',
    () async {
      seedShoot();
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);

      await ctrl.openRef(_tree);

      final state = container.read(cullControllerProvider);
      expect(state.dir, isA<SafTree>());
      expect(ctrl.storageGateway, isA<SafStorageGateway>());
      expect(state.pairs, hasLength(1));
      expect(state.pairs.single.raw.localPath, isNull);
      expect(state.pairs.single.raw.documentId, 'primary:DCIM/photo.arw');
      expect(state.pairs.single.raw.documentId, isNot('RAW'));
      expect(state.pairs.single.raw.documentId, isNotEmpty);
    },
  );

  test('openFolder(local path) still uses IoStorageGateway', () async {
    final tmp = Directory.systemTemp.createTempSync('cull_io_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File(p.join(tmp.path, 'IMG_001.ARW')).writeAsBytesSync([0, 1, 2, 3]);
    final container = await makeContainer();
    addTearDown(container.dispose);
    final ctrl = container.read(cullControllerProvider.notifier);

    await ctrl.openFolder(tmp.path);

    final state = container.read(cullControllerProvider);
    expect(state.dir, isA<LocalFolder>());
    expect((state.dir as LocalFolder).path, tmp.path);
    expect(ctrl.storageGateway, isA<IoStorageGateway>());
    expect(state.pairs, hasLength(1));
  });

  test(
    'SAF session save read_only sets CullState.error and keeps the flag',
    () async {
      seedShoot();
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openRef(_tree);
      harness.failWrites = true;

      await ctrl.keep();

      final state = container.read(cullControllerProvider);
      expect(state.flags['photo'], CullFlag.keep);
      expect(state.error, isNotNull);
      expect(state.error, contains('read_only'));
    },
  );

  test(
    'repeated identical SAF save failures remain observable',
    () async {
      seedShoot();
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openRef(_tree);
      harness.failWrites = true;

      final visible = <String>[];
      container.listen<String?>(
        cullControllerProvider.select((s) => s.error),
        (prev, next) {
          if (next != null && next != prev) visible.add(next);
        },
      );

      await ctrl.keep();
      await ctrl.skip();
      await ctrl.undo();

      final state = container.read(cullControllerProvider);
      expect(visible, hasLength(3));
      expect(visible, everyElement(contains('read_only')));
      expect(state.error, contains('read_only'));
      expect(state.flags['photo'], CullFlag.keep);
    },
  );

  test(
    'SAF save error resets after success and a later identical failure is observable',
    () async {
      seedShoot();
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openRef(_tree);

      final visible = <String>[];
      container.listen<String?>(
        cullControllerProvider.select((s) => s.error),
        (prev, next) {
          if (next != null && next != prev) visible.add(next);
        },
      );

      harness.failWrites = true;
      await ctrl.keep();
      expect(container.read(cullControllerProvider).error, contains('read_only'));
      expect(container.read(cullControllerProvider).flags['photo'], CullFlag.keep);

      harness.failWrites = false;
      await ctrl.skip();
      expect(container.read(cullControllerProvider).error, isNull);
      expect(container.read(cullControllerProvider).flags['photo'], CullFlag.skip);

      harness.failWrites = true;
      await ctrl.keep();

      final state = container.read(cullControllerProvider);
      expect(visible, hasLength(2));
      expect(visible, everyElement(contains('read_only')));
      expect(state.error, contains('read_only'));
      expect(state.flags['photo'], CullFlag.keep);
    },
  );

  test(
    'failed SAF open after local folder restores Io gateway and does not persist',
    () async {
      final tmp = Directory.systemTemp.createTempSync('cull_local_then_saf_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      File(p.join(tmp.path, 'IMG_001.ARW')).writeAsBytesSync([0, 1, 2, 3]);
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      final prefs = container.read(prefsServiceProvider);

      await ctrl.openFolder(tmp.path);
      expect(ctrl.storageGateway, isA<IoStorageGateway>());
      expect(prefs.lastCullDir, tmp.path);

      harness.failOpen = true;
      await ctrl.openRef(_tree);

      final state = container.read(cullControllerProvider);
      expect(state.dir, isA<LocalFolder>());
      expect((state.dir as LocalFolder).path, tmp.path);
      expect(state.pairs, hasLength(1));
      expect(ctrl.storageGateway, isA<IoStorageGateway>());
      expect(state.loading, isFalse);
      expect(state.error, contains('Failed to open folder'));
      expect(prefs.lastCullDir, tmp.path);
      expect(prefs.lastCullDir, isNot(_treeUri));
      expect(harness.calls.any((c) => c.method == 'delete'), isFalse);
    },
  );

  test(
    'failed local open after SAF folder restores SafStorageGateway and does not persist',
    () async {
      seedShoot();
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      final prefs = container.read(prefsServiceProvider);

      await ctrl.openRef(_tree);
      expect(ctrl.storageGateway, isA<SafStorageGateway>());
      expect(prefs.lastCullDir, _treeUri);

      await ctrl.openFolder(_treeUri);

      final state = container.read(cullControllerProvider);
      expect(state.dir, isA<SafTree>());
      expect((state.dir as SafTree).treeUri, _treeUri);
      expect(state.pairs, hasLength(1));
      expect(state.pairs.single.raw.documentId, 'primary:DCIM/photo.arw');
      expect(ctrl.storageGateway, isA<SafStorageGateway>());
      expect(state.loading, isFalse);
      expect(state.error, contains('Failed to open folder'));
      expect(prefs.lastCullDir, _treeUri);

      harness.failWrites = true;
      await ctrl.keep();
      expect(container.read(cullControllerProvider).flags['photo'], CullFlag.keep);
      expect(container.read(cullControllerProvider).error, contains('read_only'));
      expect(ctrl.storageGateway, isA<SafStorageGateway>());
    },
  );

  test('desktop session save failure stays silent', () async {
    final tmp = Directory.systemTemp.createTempSync('cull_silent_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    File(p.join(tmp.path, 'IMG_001.ARW')).writeAsBytesSync([0, 1]);
    final container = await makeContainer();
    addTearDown(container.dispose);
    final ctrl = container.read(cullControllerProvider.notifier);
    await ctrl.openFolder(tmp.path);
    tmp.deleteSync(recursive: true);

    await ctrl.keep();

    final state = container.read(cullControllerProvider);
    expect(state.error, isNull);
    expect(state.flags['IMG_001'], CullFlag.keep);
  });

  test(
    'exportTo(SafTree) uses document ids; ExportResult.outputPath is empty',
    () async {
      seedShoot();
      harness.addTree(_dest);
      final container = await makeContainer();
      addTearDown(container.dispose);
      final ctrl = container.read(cullControllerProvider.notifier);
      await ctrl.openRef(_tree);
      await ctrl.keep();

      final result = await ctrl.exportTo(_dest, includeJpgs: false);

      expect(result.outputPath, '');
      final copies = harness.calls.where((c) => c.method == 'copyTo').toList();
      expect(copies, isNotEmpty);
      final args = Map<String, Object?>.from(copies.single.arguments as Map);
      expect(args['srcDocumentId'], 'primary:DCIM/photo.arw');
      expect(args['destParentId'], _dest.documentId);
      expect(args['destParentId'], isNot('RAW'));
      expect(args.containsKey('overwrite'), isTrue);
      expect(args['overwrite'], isTrue);
      expect(args['opId'], isNotNull);
      expect(args['opId'], isNotEmpty);
    },
  );

  test('revoked grant on restore does not openFolder on the URI', () async {
    harness.hasPersisted = false;
    SharedPreferences.setMockInitialValues({'lastCullDir': _treeUri});
    final prefs = PrefsService(await SharedPreferences.getInstance());
    final pick = FilePickService(
      safChannel: SafChannel(),
      isAndroid: () => true,
      pickLocalDirectory: ({String? dialogTitle}) async => null,
    );
    final container = ProviderContainer(
      overrides: [prefsServiceProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(cullControllerProvider.notifier);

    final restored = await pick.restorePersistedFolder(
      prefs.lastCullDir,
      clearStale: prefs.clearLastCullDir,
    );
    if (restored != null) {
      await ctrl.openRef(restored);
    }

    final state = container.read(cullControllerProvider);
    expect(restored, isNull);
    expect(prefs.lastCullDir, isNull);
    expect(state.dir, isNull);
    expect(state.dir, isNot(isA<LocalFolder>()));
    expect(
      harness.calls.any((c) => c.method == 'delete'),
      isFalse,
    );
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

class _ScriptedSaf {
  final List<MethodCall> calls = <MethodCall>[];
  final Map<String, Map<String, _SafNode>> trees = {};
  bool hasPersisted = true;
  bool failWrites = false;
  bool failOpen = false;

  void addTree(SafTree tree) {
    trees[tree.treeUri] = {
      tree.documentId: _SafNode(
        documentId: tree.documentId,
        parentId: null,
        name: tree.displayName,
        mime: StorageEntry.directoryMimeType,
        isDirectory: true,
      ),
    };
  }

  void seedFile({
    required String treeUri,
    required String parentId,
    required String documentId,
    required String name,
    required Uint8List bytes,
  }) {
    trees[treeUri]![documentId] = _SafNode(
      documentId: documentId,
      parentId: parentId,
      name: name,
      mime: 'application/octet-stream',
      isDirectory: false,
      bytes: bytes,
    );
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final args = call.arguments is Map
        ? Map<String, Object?>.from(call.arguments as Map)
        : <String, Object?>{};
    switch (call.method) {
      case 'pickTree':
        return <String, Object?>{
          'treeUri': _tree.treeUri,
          'documentId': _tree.documentId,
          'displayName': _tree.displayName,
        };
      case 'takePersistable':
        return <String, Object?>{'ok': true};
      case 'hasPersisted':
        return <String, Object?>{'ok': hasPersisted};
      case 'persistedTrees':
        return <String, Object?>{'trees': <Object>[]};
      case 'listChildren':
        if (failOpen) {
          throw PlatformException(
            code: StorageException.permissionDenied,
            message: 'grant revoked',
          );
        }
        return _list(args);
      case 'childByName':
        return _child(args);
      case 'createDirectory':
        return _createDir(args);
      case 'createFile':
        return _createFile(args);
      case 'writeBytes':
        if (failWrites) {
          throw PlatformException(
            code: StorageException.readOnly,
            message: 'read only',
          );
        }
        final node = _file(args['treeUri'] as String, args['documentId'] as String);
        final bytes = args['bytes'];
        if (bytes is Uint8List) node.bytes = bytes;
        return <String, Object?>{'ok': true};
      case 'byteLength':
        return <String, Object?>{
          'size': _file(args['treeUri'] as String, args['documentId'] as String)
              .bytes
              .length,
        };
      case 'copyTo':
        return _copyTo(args);
      case 'move':
        return <String, Object?>{
          'outcome': 'renamed',
          'entry': _encode(
            _file(args['treeUri'] as String, args['documentId'] as String),
          ),
        };
      default:
        throw PlatformException(code: 'io_failure', message: call.method);
    }
  }

  Map<String, Object?> _encode(_SafNode node) => <String, Object?>{
        'documentId': node.documentId,
        'displayName': node.name,
        'mimeType': node.mime,
        'size': node.isDirectory ? null : node.bytes.length,
        'isDirectory': node.isDirectory,
      };

  _SafNode? _named(Map<String, _SafNode> nodes, String parentId, String name) {
    for (final node in nodes.values) {
      if (node.parentId == parentId && node.name == name) return node;
    }
    return null;
  }

  Object _list(Map<String, Object?> args) {
    final nodes = trees[args['treeUri'] as String];
    if (nodes == null) {
      throw PlatformException(code: StorageException.notFound, message: 'tree');
    }
    final id = args['documentId'] as String;
    if (!nodes.containsKey(id)) {
      throw PlatformException(code: StorageException.notFound, message: 'dir');
    }
    return <String, Object?>{
      'entries': [
        for (final node in nodes.values)
          if (node.parentId == id) _encode(node),
      ],
    };
  }

  Object _child(Map<String, Object?> args) {
    final nodes = trees[args['treeUri'] as String];
    if (nodes == null) {
      throw PlatformException(code: StorageException.notFound, message: 'tree');
    }
    final child = _named(
      nodes,
      args['parentDocumentId'] as String,
      args['name'] as String,
    );
    return <String, Object?>{'entry': child == null ? null : _encode(child)};
  }

  Object _createDir(Map<String, Object?> args) {
    if (failWrites) {
      throw PlatformException(
        code: StorageException.readOnly,
        message: 'read only',
      );
    }
    final nodes = trees[args['treeUri'] as String]!;
    final parentId = args['parentDocumentId'] as String;
    final name = args['name'] as String;
    final id = '$parentId/$name';
    final node = _SafNode(
      documentId: id,
      parentId: parentId,
      name: name,
      mime: StorageEntry.directoryMimeType,
      isDirectory: true,
    );
    nodes[id] = node;
    return <String, Object?>{'entry': _encode(node)};
  }

  Object _createFile(Map<String, Object?> args) {
    if (failWrites) {
      throw PlatformException(
        code: StorageException.readOnly,
        message: 'read only',
      );
    }
    final nodes = trees[args['treeUri'] as String]!;
    final parentId = args['parentDocumentId'] as String;
    final name = args['displayName'] as String;
    final id = '$parentId/$name';
    final node = _SafNode(
      documentId: id,
      parentId: parentId,
      name: name,
      mime: args['mimeType'] as String? ?? 'application/octet-stream',
      isDirectory: false,
    );
    nodes[id] = node;
    return <String, Object?>{'entry': _encode(node)};
  }

  Object _copyTo(Map<String, Object?> args) {
    final src = trees[args['srcTreeUri'] as String]![args['srcDocumentId'] as String]!;
    final destNodes = trees[args['destTreeUri'] as String]!;
    final destParentId = args['destParentId'] as String;
    final destName = args['destName'] as String;
    final id = '$destParentId/$destName';
    final copied = _SafNode(
      documentId: id,
      parentId: destParentId,
      name: destName,
      mime: src.mime,
      isDirectory: false,
      bytes: Uint8List.fromList(src.bytes),
    );
    destNodes[id] = copied;
    return <String, Object?>{
      'entry': _encode(copied),
      'bytesCopied': src.bytes.length,
    };
  }

  _SafNode _file(String treeUri, String documentId) {
    final node = trees[treeUri]![documentId];
    if (node == null || node.isDirectory) {
      throw PlatformException(code: StorageException.notFound, message: 'file');
    }
    return node;
  }
}
