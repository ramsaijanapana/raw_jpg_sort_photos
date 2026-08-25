import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/folder_ref.dart';
import 'package:photo_sorter/core/raw_preview/raw_preview_extractor.dart';
import 'package:photo_sorter/core/storage/byte_range_reader.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';

Matcher throwsStorage(String code) => throwsA(
      isA<StorageException>().having((e) => e.code, 'code', code),
    );

void _writeU32Be(Uint8List buf, int offset, int value) {
  buf[offset] = (value >> 24) & 0xFF;
  buf[offset + 1] = (value >> 16) & 0xFF;
  buf[offset + 2] = (value >> 8) & 0xFF;
  buf[offset + 3] = value & 0xFF;
}

Uint8List _jpeg({int size = 8}) {
  final buf = Uint8List(size);
  buf[0] = 0xFF;
  buf[1] = 0xD8;
  buf[size - 2] = 0xFF;
  buf[size - 1] = 0xD9;
  return buf;
}

/// Minimal little-endian TIFF with one 0x0201/0x0202 JPEG range.
Uint8List _minimalTiff(Uint8List embeddedJpeg) {
  const ifdStart = 8;
  const jpegOffset = 38;
  final total = jpegOffset + embeddedJpeg.length;
  final buf = Uint8List(total);
  buf[0] = 0x49;
  buf[1] = 0x49;
  buf[2] = 0x2A;
  buf[4] = ifdStart;
  buf[8] = 2;
  buf[10] = 0x01;
  buf[11] = 0x02;
  buf[12] = 4;
  buf[14] = 1;
  buf[18] = jpegOffset;
  buf[22] = 0x02;
  buf[23] = 0x02;
  buf[24] = 4;
  buf[26] = 1;
  final jpegLen = embeddedJpeg.length;
  buf[30] = jpegLen & 0xFF;
  buf[31] = (jpegLen >> 8) & 0xFF;
  buf[32] = (jpegLen >> 16) & 0xFF;
  buf[33] = (jpegLen >> 24) & 0xFF;
  buf.setRange(jpegOffset, jpegOffset + embeddedJpeg.length, embeddedJpeg);
  return buf;
}

Uint8List _rafWithJpeg(Uint8List jpeg, {int jpegOffset = 92}) {
  final buf = Uint8List(jpegOffset + jpeg.length);
  _writeU32Be(buf, 84, jpegOffset);
  _writeU32Be(buf, 88, jpeg.length);
  buf.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);
  return buf;
}

class RecordingByteRangeReader implements ByteRangeReader {
  RecordingByteRangeReader(this.bytes);

  final Uint8List bytes;
  int readAllCount = 0;
  final reads = <({int offset, int length})>[];

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads.add((offset: offset, length: length));
    if (offset < 0 || length < 0 || offset > bytes.length) {
      throw const StorageException(
        StorageException.invalidArg,
        'bad range',
      );
    }
    final end = (offset + length).clamp(offset, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset, end));
  }

  @override
  Future<Uint8List> readAll() async {
    readAllCount++;
    return Uint8List.fromList(bytes);
  }
}

class MemoryGateway implements StorageGateway {
  MemoryGateway(this.data, {Directory? cacheDirectory})
      : _cacheDirectory = cacheDirectory;

  final Uint8List data;
  final Directory? _cacheDirectory;
  int readAllCount = 0;
  int readRangeCount = 0;
  int byteLengthCount = 0;
  int materializeCount = 0;
  int deleteCacheCount = 0;
  final owned = <String>{};
  int _seq = 0;

  Never _stub() => throw UnimplementedError();

  @override
  Future<bool> exists(FolderRef folder) async => _stub();

  @override
  Future<List<StorageEntry>> listChildren(
    FolderRef folder, {
    String? childDocumentId,
  }) async =>
      _stub();

  @override
  Future<StorageEntry?> childByName(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async =>
      _stub();

  @override
  Future<void> createDirectory(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async =>
      _stub();

  @override
  Future<StorageEntry> createFile(
    FolderRef folder,
    String displayName, {
    required String mimeType,
    String? parentDocumentId,
  }) async =>
      _stub();

  @override
  Future<Uint8List> readAll(StorageEntry file) async {
    readAllCount++;
    return Uint8List.fromList(data);
  }

  @override
  Future<Uint8List> readRange(
    StorageEntry file, {
    required int offset,
    required int length,
  }) async {
    readRangeCount++;
    if (offset < 0 || length < 0 || offset > data.length) {
      throw const StorageException(
        StorageException.invalidArg,
        'bad range',
      );
    }
    final end = (offset + length).clamp(offset, data.length);
    return Uint8List.fromList(data.sublist(offset, end));
  }

  @override
  Future<int> byteLength(StorageEntry file) async {
    byteLengthCount++;
    return data.length;
  }

  @override
  Future<void> writeBytes(StorageEntry file, Uint8List bytes) async => _stub();

  @override
  Future<void> copyFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
    required bool overwrite,
  }) async =>
      _stub();

  @override
  Future<MoveOutcome> moveFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
  }) async =>
      _stub();

  @override
  Future<void> deleteEntry(StorageEntry entry) async => _stub();

  @override
  Future<bool> isSameFolder(FolderRef a, FolderRef b) async => _stub();

  @override
  Future<String> materializeToCache(StorageEntry file) async {
    materializeCount++;
    final dir = _cacheDirectory ?? Directory.systemTemp;
    _seq += 1;
    final cachePath = p.join(dir.path, 'ps_mat_mem_${_seq}');
    await File(cachePath).writeAsBytes(data, flush: true);
    owned.add(cachePath);
    return cachePath;
  }

  @override
  Future<void> deleteCache(String cachePath) async {
    deleteCacheCount++;
    owned.remove(cachePath);
    final file = File(cachePath);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

StorageEntry _entry({
  required FolderRef folder,
  required String name,
  String? localPath,
}) {
  return StorageEntry(
    folder: folder,
    name: name,
    mimeType: 'application/octet-stream',
    isDirectory: false,
    localPath: localPath,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('byte_range_reader_');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('fake reader JPEG at an offset', () {
    test('RAF extractPreview uses ranged reads, not readAll', () async {
      final jpeg = _jpeg(size: 16);
      const jpegOffset = 92;
      final raf = _rafWithJpeg(jpeg, jpegOffset: jpegOffset);
      final reader = RecordingByteRangeReader(raf);

      final result = await extractPreview(reader, name: 'shot.raf');

      expect(result, isNotNull);
      expect(result!.sublist(0, 2), [0xFF, 0xD8]);
      expect(reader.readAllCount, 0);
      expect(reader.reads, isNotEmpty);
      expect(
        reader.reads.any((r) => r.offset == jpegOffset && r.length == jpeg.length),
        isTrue,
      );
    });

    test('TIFF extractPreview uses ranged reads, not readAll', () async {
      final jpeg = _jpeg(size: 70000);
      final tiff = _minimalTiff(jpeg);
      final reader = RecordingByteRangeReader(tiff);

      final result = await extractPreview(reader, extension: '.arw');

      expect(result, isNotNull);
      expect(result!.length, 70000);
      expect(result[0], 0xFF);
      expect(result[1], 0xD8);
      expect(reader.readAllCount, 0);
      expect(reader.reads, isNotEmpty);
      expect(reader.reads.first.offset, 0);
    });
  });

  group('TIFF/RAF ranged versus full-read', () {
    test('failed TIFF ranged path may readAll', () async {
      final reader = RecordingByteRangeReader(
        Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]),
      );
      await extractPreview(reader, extension: '.arw');
      expect(reader.readAllCount, 1);
    });

    test('CR3 fallback uses readAll on a non-cache reader', () async {
      final reader = RecordingByteRangeReader(
        Uint8List.fromList(List<int>.filled(64, 0)),
      );
      await extractPreview(reader, extension: '.cr3');
      expect(reader.readAllCount, 1);
    });
  });

  group('IoByteRangeReader', () {
    test('reads length, a range, and all bytes from a File', () async {
      final file = File(p.join(tmp.path, 'blob.bin'));
      final payload = Uint8List.fromList([10, 20, 30, 40, 50]);
      await file.writeAsBytes(payload);
      final reader = IoByteRangeReader.fromFile(file);

      expect(reader, isA<CacheMaterializingByteRangeReader>());
      expect(await reader.length(), 5);
      expect(await reader.read(1, 2), [20, 30]);
      expect(await reader.read(5, 3), isEmpty);
      expect(await reader.read(0, 0), isEmpty);
      expect(await reader.readAll(), payload);
    });

    test('rejects negative and past-EOF ranges', () async {
      final file = File(p.join(tmp.path, 'bounds.bin'));
      await file.writeAsBytes([1, 2, 3]);
      final reader = IoByteRangeReader.fromFile(file);
      await expectLater(
        reader.read(-1, 1),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        reader.read(0, -1),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        reader.read(4, 1),
        throwsStorage(StorageException.invalidArg),
      );
    });

    test('deleteCache refuses a path it did not issue', () async {
      final file = File(p.join(tmp.path, 'src.bin'));
      await file.writeAsBytes([1]);
      final photo = File(p.join(tmp.path, 'export.arw'));
      await photo.writeAsBytes([9, 9, 9]);
      final reader = IoByteRangeReader.fromFile(file, cacheDirectory: tmp);
      await expectLater(
        reader.deleteCache(photo.path),
        throwsStorage(StorageException.invalidArg),
      );
      expect(await photo.readAsBytes(), [9, 9, 9]);
    });

    test('reads through an already-open RandomAccessFile', () async {
      final file = File(p.join(tmp.path, 'raf.bin'));
      await file.writeAsBytes([1, 2, 3, 4]);
      final raf = await file.open();
      try {
        final reader = IoByteRangeReader.fromRandomAccessFile(raf);
        expect(await reader.length(), 4);
        expect(await reader.read(2, 2), [3, 4]);
        expect(await reader.readAll(), [1, 2, 3, 4]);
      } finally {
        await raf.close();
      }
    });

    test('refuses a content URI path before I/O', () {
      const uri = 'content://auth/document/primary%3Aa.arw';
      expect(
        () => IoByteRangeReader.fromFile(File(uri)),
        throwsStorage(StorageException.invalidArg),
      );
    });

    test('materializeToCache copies via File and does not use a caller name',
        () async {
      final file = File(p.join(tmp.path, 'shot.arw'));
      await file.writeAsBytes([9, 8, 7]);
      final reader = IoByteRangeReader.fromFile(
        file,
        cacheDirectory: tmp,
      );
      final cachePath = await reader.materializeToCache();
      expect(p.basename(cachePath), startsWith('ps_mat_'));
      expect(p.basename(cachePath), isNot(contains('shot.arw')));
      expect(File(cachePath).readAsBytesSync(), [9, 8, 7]);
      await reader.deleteCache(cachePath);
      expect(File(cachePath).existsSync(), isFalse);
    });

    test('two concurrent readers materialize unique cache files', () async {
      final sourceA = File(p.join(tmp.path, 'alpha.arw'));
      final sourceB = File(p.join(tmp.path, 'beta.arw'));
      final bytesA = Uint8List.fromList([0xAA, 0x01, 0x02]);
      final bytesB = Uint8List.fromList([0xBB, 0x03, 0x04, 0x05]);
      await sourceA.writeAsBytes(bytesA);
      await sourceB.writeAsBytes(bytesB);
      final readerA = IoByteRangeReader.fromFile(
        sourceA,
        cacheDirectory: tmp,
      );
      final readerB = IoByteRangeReader.fromFile(
        sourceB,
        cacheDirectory: tmp,
      );

      final paths = await Future.wait([
        readerA.materializeToCache(),
        readerB.materializeToCache(),
      ]);
      final pathA = paths[0];
      final pathB = paths[1];

      expect(pathA, isNot(pathB));
      expect(p.basename(pathA), startsWith('ps_mat_'));
      expect(p.basename(pathB), startsWith('ps_mat_'));
      expect(p.basename(pathA), isNot(contains('alpha.arw')));
      expect(p.basename(pathB), isNot(contains('beta.arw')));
      expect(File(pathA).readAsBytesSync(), bytesA);
      expect(File(pathB).readAsBytesSync(), bytesB);

      await expectLater(
        readerA.deleteCache(pathB),
        throwsStorage(StorageException.invalidArg),
      );
      await expectLater(
        readerB.deleteCache(pathA),
        throwsStorage(StorageException.invalidArg),
      );
      expect(File(pathA).readAsBytesSync(), bytesA);
      expect(File(pathB).readAsBytesSync(), bytesB);

      await readerA.deleteCache(pathA);
      await readerB.deleteCache(pathB);
      expect(File(pathA).existsSync(), isFalse);
      expect(File(pathB).existsSync(), isFalse);
    });

    test('maps FileSystemException to io_failure or quota', () async {
      final file = File(p.join(tmp.path, 'map.bin'));
      await file.writeAsBytes([1, 2, 3]);
      final ioFail = IoByteRangeReader.fromFile(
        file,
        cacheDirectory: tmp,
        injectIo: () async {
          throw FileSystemException('permission', file.path);
        },
      );
      final quota = IoByteRangeReader.fromFile(
        file,
        cacheDirectory: tmp,
        injectIo: () async {
          throw FileSystemException(
            'No space left on device',
            file.path,
            const OSError('No space left on device', 28),
          );
        },
      );

      await expectLater(
        ioFail.length(),
        throwsA(
          isA<StorageException>()
              .having((e) => e.code, 'code', StorageException.ioFailure)
              .having((e) => e.details?['path'], 'path', file.path),
        ),
      );
      await expectLater(
        ioFail.read(0, 1),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.readAll(),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        ioFail.materializeToCache(),
        throwsStorage(StorageException.ioFailure),
      );
      await expectLater(
        quota.length(),
        throwsStorage(StorageException.quota),
      );

      var deleteCalls = 0;
      final deleteFail = IoByteRangeReader.fromFile(
        file,
        cacheDirectory: tmp,
        injectIo: () async {
          deleteCalls += 1;
          if (deleteCalls > 1) {
            throw FileSystemException('delete failed', file.path);
          }
        },
      );
      final issued = await deleteFail.materializeToCache();
      await expectLater(
        deleteFail.deleteCache(issued),
        throwsStorage(StorageException.ioFailure),
      );

      final raf = await file.open();
      try {
        final rafFail = IoByteRangeReader.fromRandomAccessFile(
          raf,
          injectIo: () async {
            throw FileSystemException('permission', file.path);
          },
        );
        await expectLater(
          rafFail.length(),
          throwsStorage(StorageException.ioFailure),
        );
        await expectLater(
          rafFail.read(0, 1),
          throwsStorage(StorageException.ioFailure),
        );
        await expectLater(
          rafFail.readAll(),
          throwsStorage(StorageException.ioFailure),
        );
      } finally {
        await raf.close();
      }
    });

    test('maps disk-full OS errors by host platform', () async {
      final file = File(p.join(tmp.path, 'disk.bin'));
      await file.writeAsBytes([1]);

      Future<void> expectMapped(int osCode, String code) async {
        final gated = IoByteRangeReader.fromFile(
          file,
          cacheDirectory: tmp,
          injectIo: () async {
            throw FileSystemException(
              'disk full',
              file.path,
              OSError('disk full', osCode),
            );
          },
        );
        await expectLater(gated.length(), throwsStorage(code));
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
      final file = File(p.join(tmp.path, 'prog.bin'));
      await file.writeAsBytes([9]);
      final argument = IoByteRangeReader.fromFile(
        file,
        injectIo: () async {
          throw ArgumentError('programmer bug');
        },
      );
      final state = IoByteRangeReader.fromFile(
        file,
        injectIo: () async {
          throw StateError('programmer bug');
        },
      );
      final typed = IoByteRangeReader.fromFile(
        file,
        injectIo: () async {
          throw const StorageException(
            StorageException.quota,
            'already typed',
          );
        },
      );
      final missing = IoByteRangeReader.fromFile(
        File(p.join(tmp.path, 'gone.bin')),
      );

      await expectLater(argument.length(), throwsA(isA<ArgumentError>()));
      await expectLater(argument.read(0, 1), throwsA(isA<ArgumentError>()));
      await expectLater(argument.readAll(), throwsA(isA<ArgumentError>()));
      await expectLater(
        argument.materializeToCache(),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(state.length(), throwsA(isA<StateError>()));
      await expectLater(
        typed.length(),
        throwsStorage(StorageException.quota),
      );
      await expectLater(
        missing.length(),
        throwsStorage(StorageException.notFound),
      );
      await expectLater(
        argument.read(-1, 1),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });

  group('GatewayByteRangeReader', () {
    test('delegates length, readRange, and readAll; never opens a content URI as a File',
        () async {
      const contentPath = 'content://auth/document/primary%3Aa.arw';
      const tree = SafTree(
        treeUri: 'content://auth/tree/primary',
        documentId: 'primary',
        displayName: 'DCIM',
      );
      final payload = Uint8List.fromList([5, 6, 7, 8]);
      final gw = MemoryGateway(payload);
      final entry = _entry(
        folder: tree,
        name: 'a.arw',
        localPath: contentPath,
      );
      final reader = GatewayByteRangeReader(gw, entry);

      expect(reader, isA<CacheMaterializingByteRangeReader>());
      expect(await reader.length(), 4);
      expect(gw.byteLengthCount, 1);
      expect(await reader.read(1, 2), [6, 7]);
      expect(gw.readRangeCount, 1);
      expect(await reader.readAll(), payload);
      expect(gw.readAllCount, 1);
    });

    test('TIFF extractPreview uses gateway readRange, not readAll or cache',
        () async {
      final tiff = _minimalTiff(_jpeg(size: 70000));
      final gw = MemoryGateway(tiff, cacheDirectory: tmp);
      final reader = GatewayByteRangeReader(
        gw,
        _entry(folder: LocalFolder(tmp.path), name: 'shot.arw'),
      );

      final result = await extractPreview(reader, name: 'shot.arw');
      expect(result, isNotNull);
      expect(result!.length, 70000);
      expect(gw.readRangeCount, greaterThan(0));
      expect(gw.readAllCount, 0);
      expect(gw.materializeCount, 0);
    });

    test('CR3 extractPreview materializes through the gateway and deletes',
        () async {
      final gw = MemoryGateway(
        Uint8List.fromList(List<int>.filled(32, 1)),
        cacheDirectory: tmp,
      );
      final reader = GatewayByteRangeReader(
        gw,
        _entry(folder: LocalFolder(tmp.path), name: 'shot.cr3'),
      );

      await extractPreview(reader, extension: '.cr3');
      expect(gw.materializeCount, 1);
      expect(gw.deleteCacheCount, 1);
      expect(gw.readAllCount, 0);
      expect(gw.owned, isEmpty);
    });

    test('failed TIFF ranged path materializes instead of readAll', () async {
      final gw = MemoryGateway(
        Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]),
        cacheDirectory: tmp,
      );
      final reader = GatewayByteRangeReader(
        gw,
        _entry(folder: LocalFolder(tmp.path), name: 'shot.dng'),
      );

      await extractPreview(reader, extension: '.dng');
      expect(gw.materializeCount, 1);
      expect(gw.deleteCacheCount, 1);
      expect(gw.readAllCount, 0);
    });
  });

  group('cache-name and traversal rejection', () {
    test('assertSafeCacheFileName matches 08A traps', () {
      expect(
        () => assertSafeCacheFileName('ok.arw'),
        returnsNormally,
      );
      for (final bad in [
        'foo/bar.arw',
        r'foo\bar.arw',
        '.',
        '..',
        'a\x00b',
        '../escape.arw',
        '',
      ]) {
        expect(
          () => assertSafeCacheFileName(bad),
          throwsStorage(StorageException.invalidArg),
          reason: bad,
        );
      }
    });

    test('IoByteRangeReader.materializeToCache rejects traversal names',
        () async {
      final file = File(p.join(tmp.path, 'shot.arw'));
      await file.writeAsBytes([1]);
      for (final bad in [
        'foo/bar.arw',
        r'foo\bar.arw',
        '.',
        '..',
        'a\x00b',
        '../escape.arw',
      ]) {
        final reader = IoByteRangeReader.fromFile(
          file,
          displayName: bad,
          cacheDirectory: tmp,
        );
        await expectLater(
          reader.materializeToCache(),
          throwsStorage(StorageException.invalidArg),
        );
      }
      final leftovers = tmp
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('ps_mat_'));
      expect(leftovers, isEmpty);
    });

    test('GatewayByteRangeReader.materializeToCache rejects before gateway',
        () async {
      final gw = MemoryGateway(Uint8List.fromList([1]), cacheDirectory: tmp);
      for (final bad in [
        'foo/bar.arw',
        r'foo\bar.arw',
        '.',
        '..',
        'a\x00b',
        '../escape.arw',
      ]) {
        final reader = GatewayByteRangeReader(
          gw,
          _entry(folder: LocalFolder(tmp.path), name: bad),
        );
        await expectLater(
          reader.materializeToCache(),
          throwsStorage(StorageException.invalidArg),
        );
      }
      expect(gw.materializeCount, 0);
    });

    test('assertSafeLocalPath refuses content URIs', () {
      expect(
        () => assertSafeLocalPath(
          'content://auth/document/primary%3Aa.arw',
        ),
        throwsStorage(StorageException.invalidArg),
      );
      expect(
        () => assertSafeLocalPath('https://example.com/a.arw'),
        throwsStorage(StorageException.invalidArg),
      );
    });
  });
}
