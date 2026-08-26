import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/local_path_classifier.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/services/saf/saf_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SafChannel.channelName);
  const treeUri =
      'content://com.android.externalstorage.documents/tree/primary%3ADCIM';
  const listedUri =
      'content://COM.ANDROID.EXTERNALSTORAGE.DOCUMENTS/tree/primary%3ADCIM';

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

  Future<PrefsService> prefsWith(Map<String, Object> initial) async {
    SharedPreferences.setMockInitialValues(initial);
    return PrefsService(await SharedPreferences.getInstance());
  }

  FilePickService androidPick() => FilePickService(
        safChannel: SafChannel(),
        isAndroid: () => true,
        pickLocalDirectory: ({String? dialogTitle}) async => null,
      );

  test(
    'lastCullDirIfExists ignores content:// and does not treat it as a local path',
    () async {
      final prefs = await prefsWith({'lastCullDir': treeUri});
      expect(prefs.lastCullDir, treeUri);
      expect(prefs.lastCullDirIfExists, isNull);
      expect(classifyLocalDirectoryPath(prefs.lastCullDir!), isNull);
    },
  );

  test('lastSortInputIfExists still returns a real local directory', () async {
    final tmp = Directory.systemTemp.createTempSync('prefs_sort_ok_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final prefs = await prefsWith({'lastSortInput': tmp.path});
    expect(prefs.lastSortInputIfExists, tmp.path);
  });

  test('lastSortInputIfExists returns null for a missing local path', () async {
    final prefs = await prefsWith({
      'lastSortInput': '/nonexistent/photo-sorter-missing-sort',
    });
    expect(prefs.lastSortInputIfExists, isNull);
    expect(prefs.lastSortInput, '/nonexistent/photo-sorter-missing-sort');
  });

  test(
    'restorePersistedFolder clears only the stale key when hasPersisted is false',
    () async {
      final prefs = await prefsWith({
        'lastCullDir': treeUri,
        'lastSortInput': treeUri,
      });
      responder = (call) {
        if (call.method == 'hasPersisted') {
          return <String, Object?>{'ok': false};
        }
        fail('unexpected ${call.method}');
      };

      final restored = await androidPick().restorePersistedFolder(
        prefs.lastCullDir,
        clearStale: prefs.clearLastCullDir,
      );
      expect(restored, isNull);
      expect(prefs.lastCullDir, isNull);
      expect(prefs.lastSortInput, treeUri);
      expect(calls.map((c) => c.method), ['hasPersisted']);
      expect(
        calls.any(
          (c) =>
              c.method == 'delete' ||
              c.method == 'copyTo' ||
              c.method == 'move',
        ),
        isFalse,
      );
    },
  );

  test(
    'restorePersistedFolder returns SafTree from persistedTrees when grant exists',
    () async {
      final prefs = await prefsWith({'lastCullDir': treeUri});
      responder = (call) {
        if (call.method == 'hasPersisted') {
          return <String, Object?>{'ok': true};
        }
        if (call.method == 'persistedTrees') {
          return <String, Object?>{
            'trees': <Object>[
              <String, Object?>{
                'treeUri': listedUri,
                'documentId': 'opaque-doc-9',
                'displayName': 'Camera Roll',
              },
            ],
          };
        }
        fail('unexpected ${call.method}');
      };

      final restored = await androidPick().restorePersistedFolder(
        prefs.lastCullDir,
        clearStale: prefs.clearLastCullDir,
      );
      expect(restored, isA<SafTree>());
      final tree = restored! as SafTree;
      expect(tree.documentId, 'opaque-doc-9');
      expect(tree.displayName, 'Camera Roll');
      expect(prefs.lastCullDir, treeUri);
    },
  );

  test(
    'restorePersistedFolder mismatch with unparsable URI clears and does not open',
    () async {
      const bad = 'content://auth/document/msf:1';
      final prefs = await prefsWith({'lastCullDir': bad});
      responder = (call) {
        if (call.method == 'hasPersisted') {
          return <String, Object?>{'ok': true};
        }
        if (call.method == 'persistedTrees') {
          return <String, Object?>{'trees': <Object>[]};
        }
        fail('unexpected ${call.method}');
      };

      final restored = await androidPick().restorePersistedFolder(
        prefs.lastCullDir,
        clearStale: prefs.clearLastCullDir,
      );
      expect(restored, isNull);
      expect(prefs.lastCullDir, isNull);
    },
  );

  test('restorePersistedFolder never Directory-opens the URI', () async {
    final prefs = await prefsWith({'lastCullDir': treeUri});
    responder = (call) {
      if (call.method == 'hasPersisted') {
        return <String, Object?>{'ok': false};
      }
      return null;
    };

    await androidPick().restorePersistedFolder(
      treeUri,
      clearStale: prefs.clearLastCullDir,
    );
    expect(prefs.lastCullDir, isNull);
    expect(prefs.lastCullDirIfExists, isNull);
  });
}
