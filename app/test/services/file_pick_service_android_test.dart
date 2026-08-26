import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SafChannel.channelName);
  const treeUri =
      'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
  const documentId = 'primary:DCIM';
  const displayName = 'DCIM';

  late List<MethodCall> calls;
  late Object? Function(MethodCall call) responder;

  setUp(() {
    calls = <MethodCall>[];
    responder = (_) => null;
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

  Map<String, Object?> args(int index) =>
      Map<String, Object?>.from(calls[index].arguments as Map);

  test(
    'Android pickTree success returns SafTree, persists, and never calls FilePicker',
    () async {
      var localInvoked = false;
      responder = (call) {
        if (call.method == 'pickTree') {
          return <String, Object?>{
            'treeUri': treeUri,
            'documentId': documentId,
            'displayName': displayName,
          };
        }
        if (call.method == 'takePersistable') {
          return <String, Object?>{'ok': true};
        }
        fail('unexpected ${call.method}');
      };

      final svc = FilePickService(
        safChannel: SafChannel(),
        isAndroid: () => true,
        pickLocalDirectory: ({String? dialogTitle}) async {
          localInvoked = true;
          return '/tmp/should-not-run';
        },
      );

      final result = await svc.pickDirectory(title: 'Choose photo folder');

      expect(localInvoked, isFalse);
      expect(calls.map((c) => c.method), ['pickTree', 'takePersistable']);
      expect(args(0)['title'], 'Choose photo folder');
      expect(args(1)['treeUri'], treeUri);
      expect(result.path, isNull);
      expect(result.warning, isNull);
      expect(result.folder, isA<SafTree>());
      final tree = result.folder! as SafTree;
      expect(tree.treeUri, treeUri);
      expect(tree.documentId, documentId);
      expect(tree.displayName, displayName);
      expect(FilePickService.folderDisplayName(tree), displayName);
      expect(FilePickService.folderDisplayName(tree), isNot(contains('://')));
    },
  );

  test('Android pickTree cancel is triple-null and not an error', () async {
    final svc = FilePickService(
      safChannel: SafChannel(),
      isAndroid: () => true,
      pickLocalDirectory: ({String? dialogTitle}) async {
        fail('FilePicker must not run on Android');
      },
    );

    responder = (_) => null;
    final fromNull = await svc.pickDirectory();
    expect(fromNull.path, isNull);
    expect(fromNull.warning, isNull);
    expect(fromNull.folder, isNull);

    responder = (_) => throw PlatformException(code: 'cancel', message: 'nope');
    final fromCancel = await svc.pickDirectory();
    expect(fromCancel.path, isNull);
    expect(fromCancel.warning, isNull);
    expect(fromCancel.folder, isNull);
  });

  test('Android takePersistable failure is a warning, not a folder', () async {
    responder = (call) {
      if (call.method == 'pickTree') {
        return <String, Object?>{
          'treeUri': treeUri,
          'documentId': documentId,
          'displayName': displayName,
        };
      }
      throw PlatformException(
        code: StorageException.permissionDenied,
        message: 'denied',
      );
    };

    final svc = FilePickService(
      safChannel: SafChannel(),
      isAndroid: () => true,
      pickLocalDirectory: ({String? dialogTitle}) async => null,
    );
    final result = await svc.pickDirectory();
    expect(result.path, isNull);
    expect(result.folder, isNull);
    expect(result.warning, directoryAccessWarning);
  });

  test('Android pickTree unsupported is a warning', () async {
    responder = (_) => throw PlatformException(
          code: StorageException.unsupported,
          message: 'cloud',
        );

    final svc = FilePickService(
      safChannel: SafChannel(),
      isAndroid: () => true,
      pickLocalDirectory: ({String? dialogTitle}) async => null,
    );
    final result = await svc.pickDirectory();
    expect(result.path, isNull);
    expect(result.folder, isNull);
    expect(result.warning, directoryAccessWarning);
  });

  test('non-Android pick still uses local picker + interpret', () async {
    final tmp = Directory.systemTemp.createTempSync('pick_non_android_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    var localInvoked = false;

    final svc = FilePickService(
      safChannel: SafChannel(),
      isAndroid: () => false,
      pickLocalDirectory: ({String? dialogTitle}) async {
        localInvoked = true;
        return tmp.path;
      },
    );

    final result = await svc.pickDirectory(title: 'Choose');
    expect(localInvoked, isTrue);
    expect(calls, isEmpty);
    expect(result.warning, isNull);
    expect(result.path, tmp.path);
    expect(result.folder, isA<LocalFolder>());
    expect((result.folder as LocalFolder).path, tmp.path);
  });

  test('interpretPickedDirectory still rejects content://', () async {
    final result = await interpretPickedDirectory(
      'content://com.android.externalstorage.documents/tree/primary%3ADCIM',
    );
    expect(result.path, isNull);
    expect(result.warning, directoryAccessWarning);
    expect(result.folder, isNull);
  });
}
