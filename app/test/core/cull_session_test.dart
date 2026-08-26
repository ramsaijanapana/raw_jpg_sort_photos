import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/cull_session.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';

void main() {
  late Directory tmp;
  late LocalFolder folder;
  late IoStorageGateway gateway;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cull_test_');
    folder = LocalFolder(tmp.path);
    gateway = IoStorageGateway();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<CullSession> loadFolder([LocalFolder? target]) =>
      CullSession.load(target ?? folder, gateway: gateway);

  Future<void> saveFolder(CullSession session, [LocalFolder? target]) =>
      session.save(target ?? folder, gateway: gateway);

  group('CullSession.load', () {
    test('returns empty session when file does not exist', () async {
      final session = await loadFolder();
      expect(session.flags, isEmpty);
    });

    test('loads keep and skip flags from valid JSON', () async {
      final file = File(p.join(tmp.path, 'cull_session.json'));
      await file.writeAsString('{"IMG_001":"keep","IMG_002":"skip"}');

      final session = await loadFolder();
      expect(session.flagFor('IMG_001'), CullFlag.keep);
      expect(session.flagFor('IMG_002'), CullFlag.skip);
    });

    test('missing stem returns undecided', () async {
      final file = File(p.join(tmp.path, 'cull_session.json'));
      await file.writeAsString('{"IMG_001":"keep"}');

      final session = await loadFolder();
      expect(session.flagFor('IMG_999'), CullFlag.undecided);
    });

    test('corrupt JSON returns empty session without throwing', () async {
      final file = File(p.join(tmp.path, 'cull_session.json'));
      await file.writeAsString('{ this is not valid json }');

      final session = await loadFolder();
      expect(session.flags, isEmpty);
    });

    test('empty JSON object returns empty session', () async {
      final file = File(p.join(tmp.path, 'cull_session.json'));
      await file.writeAsString('{}');

      final session = await loadFolder();
      expect(session.flags, isEmpty);
    });

    test('unknown flag values are ignored (treated as undecided)', () async {
      final file = File(p.join(tmp.path, 'cull_session.json'));
      await file.writeAsString('{"IMG_001":"maybe","IMG_002":"keep"}');

      final session = await loadFolder();
      expect(session.flagFor('IMG_001'), CullFlag.undecided);
      expect(session.flagFor('IMG_002'), CullFlag.keep);
    });

    test('JSON array (wrong type) returns empty session', () async {
      final file = File(p.join(tmp.path, 'cull_session.json'));
      await file.writeAsString('["keep", "skip"]');

      final session = await loadFolder();
      expect(session.flags, isEmpty);
    });
  });

  group('CullSession.save', () {
    test('saves keep and skip flags, omits undecided', () async {
      final session = CullSession({
        'IMG_001': CullFlag.keep,
        'IMG_002': CullFlag.skip,
        'IMG_003': CullFlag.undecided,
      });

      await saveFolder(session);

      final file = File(p.join(tmp.path, 'cull_session.json'));
      expect(file.existsSync(), isTrue);

      final decoded = jsonDecode(await file.readAsString()) as Map;
      expect(decoded.containsKey('IMG_001'), isTrue);
      expect(decoded['IMG_001'], 'keep');
      expect(decoded.containsKey('IMG_002'), isTrue);
      expect(decoded['IMG_002'], 'skip');
      expect(decoded.containsKey('IMG_003'), isFalse);
    });

    test('saves empty object when all flags undecided', () async {
      final session = CullSession({
        'A': CullFlag.undecided,
      });

      await saveFolder(session);

      final file = File(p.join(tmp.path, 'cull_session.json'));
      final decoded = jsonDecode(await file.readAsString()) as Map;
      expect(decoded, isEmpty);
    });

    test('save failure is silent (no throw)', () async {
      final nonExist = Directory(p.join(tmp.path, 'non_existent_dir'));
      final session = CullSession({'A': CullFlag.keep});

      await expectLater(
        saveFolder(session, LocalFolder(nonExist.path)),
        completes,
      );
      expect(nonExist.existsSync(), isFalse);
    });

    test('save ignoreErrors false rethrows', () async {
      final nonExist = Directory(p.join(tmp.path, 'non_existent_dir'));
      final session = CullSession({'A': CullFlag.keep});

      await expectLater(
        session.save(
          LocalFolder(nonExist.path),
          gateway: gateway,
          ignoreErrors: false,
        ),
        throwsA(isA<Object>()),
      );
      await expectLater(
        session.save(LocalFolder(nonExist.path), gateway: gateway),
        completes,
      );
      expect(nonExist.existsSync(), isFalse);
    });
  });

  group('Round-trip', () {
    test('save then load produces identical flags', () async {
      final original = CullSession({
        'photo1': CullFlag.keep,
        'photo2': CullFlag.skip,
        'photo3': CullFlag.keep,
      });

      await saveFolder(original);
      final loaded = await loadFolder();

      expect(loaded.flagFor('photo1'), CullFlag.keep);
      expect(loaded.flagFor('photo2'), CullFlag.skip);
      expect(loaded.flagFor('photo3'), CullFlag.keep);
    });

    test('format matches Python format: {"stem": "keep"|"skip"}', () async {
      final session = CullSession({
        'DSC_0001': CullFlag.keep,
        'DSC_0002': CullFlag.skip,
      });
      await saveFolder(session);

      final file = File(p.join(tmp.path, 'cull_session.json'));
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;

      expect(decoded['DSC_0001'], 'keep');
      expect(decoded['DSC_0002'], 'skip');
      expect(decoded.length, 2);
    });
  });

  group('setFlag / flagFor', () {
    test('setFlag updates flag correctly', () {
      final session = CullSession();
      session.setFlag('photo1', CullFlag.keep);
      expect(session.flagFor('photo1'), CullFlag.keep);

      session.setFlag('photo1', CullFlag.skip);
      expect(session.flagFor('photo1'), CullFlag.skip);
    });

    test('setFlag undecided removes the entry', () {
      final session = CullSession({'photo1': CullFlag.keep});
      session.setFlag('photo1', CullFlag.undecided);
      expect(session.flags.containsKey('photo1'), isFalse);
      expect(session.flagFor('photo1'), CullFlag.undecided);
    });
  });
}
