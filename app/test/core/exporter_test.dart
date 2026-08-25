import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/exporter.dart';
import 'package:photo_sorter/core/cull_session.dart';
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/storage/io_storage_gateway.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';

void main() {
  late Directory src;
  late Directory dest;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('exporter_src_');
    dest = await Directory.systemTemp.createTemp('exporter_dest_');
  });

  tearDown(() async {
    await src.delete(recursive: true);
    await dest.delete(recursive: true);
  });

  Future<File> createFile(String path, [String content = 'data']) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  StorageEntry entryFor(File file) {
    return StorageEntry(
      folder: LocalFolder(src.path),
      name: p.basename(file.path),
      mimeType: 'application/octet-stream',
      isDirectory: false,
      localPath: file.path,
    );
  }

  Future<PhotoPair> makePair({
    required String stem,
    required String rawExt,
    String? jpgExt,
  }) async {
    final rawFile =
        await createFile(p.join(src.path, '$stem$rawExt'), 'raw_content');
    File? jpgFile;
    if (jpgExt != null) {
      jpgFile =
          await createFile(p.join(src.path, '$stem$jpgExt'), 'jpg_content');
    }
    return PhotoPair(
      stem: stem,
      raw: entryFor(rawFile),
      jpg: jpgFile == null ? null : entryFor(jpgFile),
    );
  }

  Future<ExportResult> export({
    required List<PhotoPair> pairs,
    required CullSession session,
    required bool includeJpgs,
    Directory? destination,
    StorageGateway? gateway,
  }) {
    return exportKept(
      source: LocalFolder(src.path),
      destination: LocalFolder((destination ?? dest).path),
      gateway: gateway ?? IoStorageGateway(),
      pairs: pairs,
      session: session,
      includeJpgs: includeJpgs,
    );
  }

  group('exportKept', () {
    test('copies kept RAW files', () async {
      final pair = await makePair(stem: 'DSC_0001', rawExt: '.arw');
      final session = CullSession({'DSC_0001': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'DSC_0001.arw')).existsSync(), isTrue);
    });

    test('copies kept RAW and JPG when includeJpgs=true', () async {
      final pair =
          await makePair(stem: 'DSC_0002', rawExt: '.nef', jpgExt: '.jpg');
      final session = CullSession({'DSC_0002': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 2);
      expect(File(p.join(dest.path, 'DSC_0002.nef')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'DSC_0002.jpg')).existsSync(), isTrue);
    });

    test('respects includeJpgs=false: only copies RAW', () async {
      final pair =
          await makePair(stem: 'DSC_0003', rawExt: '.cr2', jpgExt: '.jpg');
      final session = CullSession({'DSC_0003': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'DSC_0003.cr2')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'DSC_0003.jpg')).existsSync(), isFalse);
    });

    test('skips non-keep flagged pairs', () async {
      final pair1 = await makePair(stem: 'DSC_0004', rawExt: '.arw');
      final pair2 = await makePair(stem: 'DSC_0005', rawExt: '.arw');
      final pair3 = await makePair(stem: 'DSC_0006', rawExt: '.arw');

      final session = CullSession({
        'DSC_0004': CullFlag.keep,
        'DSC_0005': CullFlag.skip,
      });

      final result = await export(
        pairs: [pair1, pair2, pair3],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'DSC_0004.arw')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'DSC_0005.arw')).existsSync(), isFalse);
      expect(File(p.join(dest.path, 'DSC_0006.arw')).existsSync(), isFalse);
    });

    test('skips skip-flagged pairs', () async {
      final pair =
          await makePair(stem: 'DSC_0007', rawExt: '.nef', jpgExt: '.jpg');
      final session = CullSession({'DSC_0007': CullFlag.skip});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 0);
    });

    test('skips undecided pairs', () async {
      final pair = await makePair(stem: 'DSC_0008', rawExt: '.arw');
      final session = CullSession();

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 0);
    });

    test('creates destination directory if needed', () async {
      final newDest = Directory(p.join(dest.path, 'subdir', 'nested'));
      final pair = await makePair(stem: 'DSC_0009', rawExt: '.arw');
      final session = CullSession({'DSC_0009': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
        destination: newDest,
      );

      expect(result.copied, 1);
      expect(newDest.existsSync(), isTrue);
    });

    test('returned outputPath matches destination', () async {
      final pair = await makePair(stem: 'DSC_0010', rawExt: '.arw');
      final session = CullSession({'DSC_0010': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.outputPath, dest.path);
    });

    test('overwrites existing file (matches Python shutil.copy2 behavior)',
        () async {
      final pair = await makePair(stem: 'DSC_0011', rawExt: '.arw');
      await createFile(p.join(dest.path, 'DSC_0011.arw'), 'old_content');

      final session = CullSession({'DSC_0011': CullFlag.keep});
      await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(
        File(p.join(dest.path, 'DSC_0011.arw')).readAsStringSync(),
        'raw_content',
      );
    });

    test('handles raw-only pair with includeJpgs=true gracefully', () async {
      final pair = await makePair(stem: 'DSC_0012', rawExt: '.arw');
      final session = CullSession({'DSC_0012': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 1);
    });

    test('skips a missing source raw, still copies the rest (P0-7)', () async {
      final pair1 = await makePair(stem: 'GOOD', rawExt: '.arw');
      final pair2 = await makePair(stem: 'GONE', rawExt: '.arw');
      await File(pair2.raw.localPath!).delete();

      final session = CullSession({
        'GOOD': CullFlag.keep,
        'GONE': CullFlag.keep,
      });

      final result = await export(
        pairs: [pair2, pair1],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'GOOD.arw')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'GONE.arw')).existsSync(), isFalse);
    });

    test('empty pairs list returns zero copied', () async {
      final session = CullSession();

      final result = await export(
        pairs: [],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 0);
    });

    test('export overwrite preserves old dest on injected failure', () async {
      final pair = await makePair(stem: 'FAIL_OW', rawExt: '.arw');
      await createFile(p.join(dest.path, 'FAIL_OW.arw'), 'old_content');
      final session = CullSession({'FAIL_OW': CullFlag.keep});
      final failing = IoStorageGateway(
        replaceFile: (temp, destPath) async {
          throw FileSystemException('replace blocked', destPath);
        },
      );

      await expectLater(
        export(
          pairs: [pair],
          session: session,
          includeJpgs: false,
          gateway: failing,
        ),
        throwsA(isA<StorageException>()),
      );
      expect(
        File(p.join(dest.path, 'FAIL_OW.arw')).readAsStringSync(),
        'old_content',
      );
    });

    test('export overwrite replaces dest on success', () async {
      final pair = await makePair(stem: 'OK_OW', rawExt: '.arw');
      await createFile(p.join(dest.path, 'OK_OW.arw'), 'old_content');
      final session = CullSession({'OK_OW': CullFlag.keep});

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );
      expect(result.copied, 1);
      expect(
        File(p.join(dest.path, 'OK_OW.arw')).readAsStringSync(),
        'raw_content',
      );
    });

    test('rejects LocalFolder content URI with invalid_arg before local I/O',
        () async {
      const uri = 'content://com.android.externalstorage.documents/tree/primary';
      final pair = await makePair(stem: 'URI', rawExt: '.arw');
      await expectLater(
        exportKept(
          source: const LocalFolder(uri),
          destination: const LocalFolder(uri),
          gateway: IoStorageGateway(),
          pairs: [pair],
          session: CullSession({'URI': CullFlag.keep}),
          includeJpgs: false,
        ),
        throwsA(
          isA<StorageException>().having(
            (e) => e.code,
            'code',
            StorageException.invalidArg,
          ),
        ),
      );
    });

    test('source absent before copy: zero copied, no write attempt', () async {
      final pair = await makePair(stem: 'ABSENT', rawExt: '.arw');
      await File(pair.raw.localPath!).delete();
      final session = CullSession({'ABSENT': CullFlag.keep});
      final gateway = _ExportOriginGateway();

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
        gateway: gateway,
      );

      expect(result.copied, 0);
      expect(gateway.copyFileCalls, 0);
      expect(File(p.join(dest.path, 'ABSENT.arw')).existsSync(), isFalse);
    });

    test('source disappears during copyFile not_found: zero copied', () async {
      final pair = await makePair(stem: 'VANISH', rawExt: '.arw');
      final session = CullSession({'VANISH': CullFlag.keep});
      final gateway = _ExportOriginGateway(
        deleteOnCopy: File(pair.raw.localPath!),
      );

      final result = await export(
        pairs: [pair],
        session: session,
        includeJpgs: false,
        gateway: gateway,
      );

      expect(result.copied, 0);
      expect(gateway.copyFileCalls, 1);
      expect(File(p.join(dest.path, 'VANISH.arw')).existsSync(), isFalse);
    });

    test(
        'source still present while copyFile not_found for dest parent '
        'propagates the exact error', () async {
      final pair = await makePair(stem: 'DEST_GONE', rawExt: '.arw');
      await createFile(p.join(dest.path, 'DEST_GONE.arw'), 'old_content');
      final session = CullSession({'DEST_GONE': CullFlag.keep});
      const destMissing = StorageException(
        StorageException.notFound,
        'destination folder not found',
      );
      final gateway = _ExportOriginGateway(copyFileThrow: destMissing);

      await expectLater(
        export(
          pairs: [pair],
          session: session,
          includeJpgs: false,
          gateway: gateway,
        ),
        throwsA(same(destMissing)),
      );
      expect(gateway.copyFileCalls, 1);
      expect(
        File(p.join(dest.path, 'DEST_GONE.arw')).readAsStringSync(),
        'old_content',
      );
    });

    test('non-not_found storage errors still propagate', () async {
      final pair = await makePair(stem: 'DENIED', rawExt: '.arw');
      final session = CullSession({'DENIED': CullFlag.keep});
      const denied = StorageException(
        StorageException.permissionDenied,
        'read only',
      );
      final gateway = _ExportOriginGateway(copyFileThrow: denied);

      await expectLater(
        export(
          pairs: [pair],
          session: session,
          includeJpgs: false,
          gateway: gateway,
        ),
        throwsA(same(denied)),
      );
      expect(gateway.copyFileCalls, 1);
    });

    test('copies a RAW/ source found by folder and name', () async {
      final rawFile = await createFile(
        p.join(src.path, 'RAW', 'IN_RAW.arw'),
        'raw_content',
      );
      final pair = PhotoPair(
        stem: 'IN_RAW',
        raw: StorageEntry(
          folder: LocalFolder(src.path),
          name: 'IN_RAW.arw',
          mimeType: 'application/octet-stream',
          isDirectory: false,
          localPath: rawFile.path,
        ),
      );
      final gateway = _ExportOriginGateway();

      final result = await export(
        pairs: [pair],
        session: CullSession({'IN_RAW': CullFlag.keep}),
        includeJpgs: false,
        gateway: gateway,
      );

      expect(result.copied, 1);
      expect(gateway.copyFileCalls, 1);
      expect(File(p.join(dest.path, 'IN_RAW.arw')).existsSync(), isTrue);
    });
  });
}

/// Production [IoStorageGateway] with scripted [copyFile] origin cases.
class _ExportOriginGateway extends IoStorageGateway {
  _ExportOriginGateway({
    this.copyFileThrow,
    this.deleteOnCopy,
  });

  final Object? copyFileThrow;
  final File? deleteOnCopy;
  int copyFileCalls = 0;

  @override
  Future<void> copyFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
    required bool overwrite,
  }) async {
    copyFileCalls++;
    final disappearing = deleteOnCopy;
    if (disappearing != null && await disappearing.exists()) {
      await disappearing.delete();
    }
    final error = copyFileThrow;
    if (error != null) {
      throw error;
    }
    return super.copyFile(
      source,
      destFolder,
      destName,
      destParentDocumentId: destParentDocumentId,
      overwrite: overwrite,
    );
  }
}
