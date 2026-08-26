import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';
import 'package:photo_sorter/main.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';
import 'package:photo_sorter/state/cull_controller.dart';
import 'package:photo_sorter/state/sort_controller.dart';
import 'package:photo_sorter/ui/sort/sort_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _src = SafTree(
  treeUri:
      'content://com.android.externalstorage.documents/tree/primary%3ADCIM',
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
    for (final v
        in TestWidgetsFlutterBinding.instance.platformDispatcher.views) {
      // ignore: invalid_use_of_visible_for_testing_member
      v.resetPhysicalSize();
    }
  });

  Future<PrefsService> prefs() async {
    SharedPreferences.setMockInitialValues({});
    return PrefsService(await SharedPreferences.getInstance());
  }

  FilePickService androidPick() => FilePickService(
        safChannel: SafChannel(),
        isAndroid: () => true,
        pickLocalDirectory: ({String? dialogTitle}) async {
          fail('FilePicker must not run');
        },
      );

  testWidgets(
    'Review export snackbar uses display name not outputPath URI',
    (tester) async {
      harness.addTree(_src);
      harness.addTree(_dest);
      harness.seedFile(
        treeUri: _src.treeUri,
        parentId: _src.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1]),
      );
      harness.pickTree = <String, Object?>{
        'treeUri': _dest.treeUri,
        'documentId': _dest.documentId,
        'displayName': _dest.displayName,
      };
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(await prefs()),
          filePickServiceProvider.overrideWithValue(androidPick()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PhotoSorterApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Review').last);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.runAsync(() async {
        await container.read(cullControllerProvider.notifier).openRef(_src);
        await container.read(cullControllerProvider.notifier).keep();
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.runAsync(() async {
        await tester.tap(find.textContaining('Export'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('Copied'), findsOneWidget);
      expect(find.textContaining('Export'), findsWidgets);
      expect(find.textContaining('content://'), findsNothing);
    },
  );

  testWidgets(
    'CullState.error SnackBar shows SAF session-save failure',
    (tester) async {
      harness.addTree(_src);
      harness.seedFile(
        treeUri: _src.treeUri,
        parentId: _src.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1]),
      );
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(await prefs()),
          filePickServiceProvider.overrideWithValue(androidPick()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const PhotoSorterApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Review').last);
      await tester.pump(const Duration(milliseconds: 100));

      await tester.runAsync(() async {
        await container.read(cullControllerProvider.notifier).openRef(_src);
      });
      await tester.pump();
      harness.failWrites = true;
      await tester.runAsync(() async {
        await container.read(cullControllerProvider.notifier).keep();
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('read_only'), findsOneWidget);
    },
  );

  testWidgets(
    'Sort done card does not claim a filesystem path for SAF',
    (tester) async {
      harness.pickTree = <String, Object?>{
        'treeUri': _src.treeUri,
        'documentId': _src.documentId,
        'displayName': _src.displayName,
      };
      harness.addTree(_src);
      harness.seedFile(
        treeUri: _src.treeUri,
        parentId: _src.documentId,
        documentId: 'primary:DCIM/photo.arw',
        name: 'photo.arw',
        bytes: Uint8List.fromList([1, 2]),
      );
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(await prefs()),
          filePickServiceProvider.overrideWithValue(androidPick()),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SortScreen()),
        ),
      );
      await tester.pump();

      await tester.runAsync(() async {
        await container.read(sortControllerProvider.notifier).pickInput();
        await container.read(sortControllerProvider.notifier).start();
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('content://'), findsNothing);
      expect(find.text('Moved into '), findsNothing);
      expect(find.textContaining('Moved into DCIM'), findsOneWidget);
      expect(find.textContaining('All done!'), findsOneWidget);
    },
  );
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
  final Map<String, Map<String, _SafNode>> trees = {};
  Object? pickTree;
  bool failWrites = false;

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
    final args = call.arguments is Map
        ? Map<String, Object?>.from(call.arguments as Map)
        : <String, Object?>{};
    switch (call.method) {
      case 'pickTree':
        return pickTree;
      case 'takePersistable':
        return <String, Object?>{'ok': true};
      case 'hasPersisted':
        return <String, Object?>{'ok': true};
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
          'size': trees[args['treeUri'] as String]![args['documentId'] as String]!
              .bytes
              .length,
        };
      case 'copyTo':
        return _copyTo(args);
      case 'move':
        final src = trees[args['treeUri'] as String]![args['documentId'] as String]!;
        src.parentId = args['destParentId'] as String;
        src.name = args['destName'] as String;
        return <String, Object?>{
          'outcome': 'renamed',
          'entry': _encode(src),
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
    final nodes = trees[args['treeUri'] as String]!;
    final id = args['documentId'] as String;
    return <String, Object?>{
      'entries': [
        for (final node in nodes.values)
          if (node.parentId == id) _encode(node),
      ],
    };
  }

  Object _child(Map<String, Object?> args) {
    final nodes = trees[args['treeUri'] as String]!;
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
}
