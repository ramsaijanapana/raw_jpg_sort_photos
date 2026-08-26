import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';
import 'package:photo_sorter/core/storage/saf_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';
import 'package:photo_sorter/state/sort_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _treeUri =
    'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
const _tree = SafTree(
  treeUri: _treeUri,
  documentId: 'primary:DCIM',
  displayName: 'DCIM',
);

Map<String, Object?> _treeMap() => <String, Object?>{
      'treeUri': _tree.treeUri,
      'documentId': _tree.documentId,
      'displayName': _tree.displayName,
    };

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

  Future<ProviderContainer> containerWith({
    Map<String, Object> prefs = const {},
    bool android = true,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final prefsService = PrefsService(await SharedPreferences.getInstance());
    return ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(prefsService),
        filePickServiceProvider.overrideWithValue(
          FilePickService(
            safChannel: SafChannel(),
            isAndroid: () => android,
            pickLocalDirectory: ({String? dialogTitle}) async {
              fail('FilePicker must not run for this oracle');
            },
          ),
        ),
      ],
    );
  }

  test(
    'pickInput on Android stores SafTree, persistable treeUri, and display name — never FilePicker path',
    () async {
      harness.pickTree = _treeMap();
      final container = await containerWith();
      addTearDown(container.dispose);
      final ctrl = container.read(sortControllerProvider.notifier);

      await ctrl.pickInput();

      final state = container.read(sortControllerProvider);
      expect(state.inputFolder, isA<SafTree>());
      expect(state.inputPath, isNull);
      expect(container.read(prefsServiceProvider).lastSortInput, _tree.treeUri);
      expect(ctrl.storageGateway, isA<SafStorageGateway>());
      final label = FilePickService.folderDisplayName(state.inputFolder!);
      expect(label, 'DCIM');
      expect(label, isNot(contains('://')));
      expect(label, isNot(_tree.documentId));
      expect(harness.methods, containsAll(['pickTree', 'takePersistable']));
    },
  );

  test('cancelled pickInput changes nothing and sets no error', () async {
    final tmp = Directory.systemTemp.createTempSync('sort_cancel_pick_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    harness.pickTree = null;
    final container = await containerWith();
    addTearDown(container.dispose);
    final ctrl = container.read(sortControllerProvider.notifier);
    await ctrl.setInput(tmp.path);
    final before = container.read(sortControllerProvider);

    await ctrl.pickInput();

    final after = container.read(sortControllerProvider);
    expect(after.inputFolder, before.inputFolder);
    expect(after.inputPath, before.inputPath);
    expect(after.phase, before.phase);
    expect(after.message, before.message);
  });

  test(
    'revoked lastSortInput on restore clears prefs and requests reselection',
    () async {
      harness.hasPersisted = false;
      final container = await containerWith(prefs: {'lastSortInput': _treeUri});
      addTearDown(container.dispose);
      final ctrl = container.read(sortControllerProvider.notifier);

      await ctrl.restoreLastInput();

      final state = container.read(sortControllerProvider);
      expect(container.read(prefsServiceProvider).lastSortInput, isNull);
      expect(state.inputFolder, isNull);
      expect(state.phase, SortPhase.error);
      expect(state.message, directoryAccessWarning);
      expect(state.inputFolder, isNot(isA<LocalFolder>()));
      expect(
        harness.methods.contains('delete'),
        isFalse,
      );
    },
  );

  test(
    'start() on SafTree uses SafStorageGateway and empty outputPath',
    () async {
      harness.pickTree = _treeMap();
      harness.addTree(_tree);
      harness.seedFile(
        treeUri: _tree.treeUri,
        parentId: _tree.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1, 2]),
      );
      final container = await containerWith();
      addTearDown(container.dispose);
      final ctrl = container.read(sortControllerProvider.notifier);

      await ctrl.pickInput();
      await ctrl.start();

      final state = container.read(sortControllerProvider);
      expect(ctrl.storageGateway, isA<SafStorageGateway>());
      expect(state.result, isNotNull);
      expect(state.result!.outputPath, '');
      expect(state.message, isNull);
      expect(state.message, isNot(contains('content://')));
      final moves = harness.calls.where((c) => c.method == 'move');
      expect(moves, isNotEmpty);
      for (final call in moves) {
        final args = Map<String, Object?>.from(call.arguments as Map);
        expect(args['documentId'], 'primary:DCIM/photo.arw');
        expect(args['destParentId'], isNot('RAW'));
        expect(args['destParentId'], 'primary:DCIM/RAW');
      }
      expect(
        harness.calls.any((c) => c.method == 'childByName' &&
            (c.arguments as Map)['name'] == 'RAW'),
        isTrue,
      );
    },
  );

  test('desktop setInput stays on IoStorageGateway', () async {
    final tmp = Directory.systemTemp.createTempSync('sort_io_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/shot.arw').writeAsBytesSync([1]);
    SharedPreferences.setMockInitialValues({});
    final prefs = PrefsService(await SharedPreferences.getInstance());
    final container = ProviderContainer(
      overrides: [prefsServiceProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    final ctrl = container.read(sortControllerProvider.notifier);

    await ctrl.setInput(tmp.path);
    expect(ctrl.storageGateway, isA<IoStorageGateway>());
    await ctrl.start();
    expect(ctrl.storageGateway, isA<IoStorageGateway>());
    expect(container.read(sortControllerProvider).phase, SortPhase.done);
  });

  test('mixed LocalFolder input and SafTree output is an error', () async {
    final tmp = Directory.systemTemp.createTempSync('sort_mixed_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/shot.arw').writeAsBytesSync([1]);
    harness.pickTree = _treeMap();
    final container = await containerWith();
    addTearDown(container.dispose);
    final ctrl = container.read(sortControllerProvider.notifier);

    await ctrl.setInput(tmp.path);
    await ctrl.pickOutput();
    harness.calls.clear();
    await ctrl.start();

    final state = container.read(sortControllerProvider);
    expect(state.phase, SortPhase.error);
    expect(state.result, isNull);
    expect(
      harness.calls.any((c) => c.method == 'move' || c.method == 'copyTo'),
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
  Object? pickTree = _treeMap();
  bool hasPersisted = true;
  bool failWrites = false;

  List<String> get methods => calls.map((c) => c.method).toList();

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
        return pickTree;
      case 'takePersistable':
        return <String, Object?>{'ok': true};
      case 'hasPersisted':
        return <String, Object?>{'ok': hasPersisted};
      case 'persistedTrees':
        return <String, Object?>{'trees': <Object>[]};
      case 'listChildren':
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
        return <String, Object?>{'ok': true};
      case 'byteLength':
        return <String, Object?>{
          'size': _file(args['treeUri'] as String, args['documentId'] as String)
              .bytes
              .length,
        };
      case 'move':
        return _move(args);
      case 'copyTo':
        return _copyTo(args);
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

  Object _move(Map<String, Object?> args) {
    final nodes = trees[args['treeUri'] as String]!;
    final src = nodes[args['documentId'] as String]!;
    src.parentId = args['destParentId'] as String;
    src.name = args['destName'] as String;
    return <String, Object?>{'outcome': 'renamed', 'entry': _encode(src)};
  }

  Object _copyTo(Map<String, Object?> args) {
    final srcNodes = trees[args['srcTreeUri'] as String]!;
    final src = srcNodes[args['srcDocumentId'] as String]!;
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
