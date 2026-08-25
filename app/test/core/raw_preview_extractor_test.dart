import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/raw_preview/raw_preview_extractor.dart';
import 'package:photo_sorter/core/storage/byte_range_reader.dart';
import 'package:photo_sorter/core/storage/storage_gateway.dart';

/// Writes a big-endian u32 into [buf] at [offset].
void _writeU32Be(Uint8List buf, int offset, int value) {
  buf[offset] = (value >> 24) & 0xFF;
  buf[offset + 1] = (value >> 16) & 0xFF;
  buf[offset + 2] = (value >> 8) & 0xFF;
  buf[offset + 3] = value & 0xFF;
}

void main() {
  group('RAF bounds checking (P1-4)', () {
    test('declared offset+length beyond EOF returns null without throwing', () {
      // 200-byte RAF buffer; header declares a preview at offset 1000 with
      // length 5000 — both well past EOF.
      final buf = Uint8List(200);
      _writeU32Be(buf, 84, 1000); // offset
      _writeU32Be(buf, 88, 5000); // length

      late Uint8List? result;
      expect(() => result = extractPreviewBytes(buf, '.raf'), returnsNormally);
      expect(result, isNull);
    });

    test('declared length extends just past EOF returns null', () {
      final buf = Uint8List(300);
      _writeU32Be(buf, 84, 100); // offset within file
      _writeU32Be(buf, 88, 1000); // 100 + 1000 = 1100 > 300

      expect(() => extractPreviewBytes(buf, '.raf'), returnsNormally);
      expect(extractPreviewBytes(buf, '.raf'), isNull);
    });

    test('buffer shorter than RAF header returns null', () {
      final buf = Uint8List(50);
      expect(extractPreviewBytes(buf, '.raf'), isNull);
    });

    test('valid in-bounds RAF preview is returned', () {
      // Place a tiny valid JPEG at offset 92.
      const jpegOffset = 92;
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      final buf = Uint8List(jpegOffset + jpeg.length);
      _writeU32Be(buf, 84, jpegOffset);
      _writeU32Be(buf, 88, jpeg.length);
      buf.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);

      final result = extractPreviewBytes(buf, '.raf');
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
    });
  });

  group('extractPreview through ByteRangeReader', () {
    test('fake reader serves a known JPEG at a RAF offset without readAll',
        () async {
      const jpegOffset = 92;
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      final buf = Uint8List(jpegOffset + jpeg.length);
      _writeU32Be(buf, 84, jpegOffset);
      _writeU32Be(buf, 88, jpeg.length);
      buf.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);
      final reader = _RecordingReader(buf);

      final result = await extractPreview(reader, extension: '.raf');
      expect(result, isNotNull);
      expect(result, jpeg);
      expect(reader.readAllCount, 0);
      expect(
        reader.reads.any(
          (r) => r.offset == jpegOffset && r.length == jpeg.length,
        ),
        isTrue,
      );
    });

    test('TIFF ranged path does not call readAll', () async {
      final jpeg = Uint8List(70000);
      jpeg[0] = 0xFF;
      jpeg[1] = 0xD8;
      jpeg[69998] = 0xFF;
      jpeg[69999] = 0xD9;
      final tiff = _minimalLeTiff(jpeg);
      final reader = _RecordingReader(tiff);

      final result = await extractPreview(reader, name: 'photo.cr2');
      expect(result, isNotNull);
      expect(result!.length, 70000);
      expect(reader.readAllCount, 0);
    });

    test('TIFF ranged failure falls back to readAll', () async {
      final reader = _RecordingReader(Uint8List(16));
      await extractPreview(reader, extension: '.nef');
      expect(reader.readAllCount, 1);
    });

    test('extractPreviewBytes stays a pure bytes API', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      const jpegOffset = 92;
      final buf = Uint8List(jpegOffset + jpeg.length);
      _writeU32Be(buf, 84, jpegOffset);
      _writeU32Be(buf, 88, jpeg.length);
      buf.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);
      expect(extractPreviewBytes(buf, '.raf'), jpeg);
    });

    test('extractPreview(File) wraps the local file and returns the RAF JPEG',
        () async {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      const jpegOffset = 92;
      final buf = Uint8List(jpegOffset + jpeg.length);
      _writeU32Be(buf, 84, jpegOffset);
      _writeU32Be(buf, 88, jpeg.length);
      buf.setRange(jpegOffset, jpegOffset + jpeg.length, jpeg);

      final dir = await Directory.systemTemp.createTemp('extract_preview_file_');
      try {
        final file = File(p.join(dir.path, 'shot.raf'));
        await file.writeAsBytes(buf);
        final result = await extractPreview(file);
        expect(result, jpeg);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('extractPreview(File) refuses a content URI path', () async {
      const uri = 'content://auth/document/primary%3Aa.arw';
      await expectLater(
        extractPreview(File(uri)),
        throwsA(
          isA<StorageException>().having(
            (e) => e.code,
            'code',
            StorageException.invalidArg,
          ),
        ),
      );
    });
  });
}

class _RecordingReader implements ByteRangeReader {
  _RecordingReader(this.bytes);

  final Uint8List bytes;
  int readAllCount = 0;
  final reads = <({int offset, int length})>[];

  @override
  Future<int> length() async => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    reads.add((offset: offset, length: length));
    final end = (offset + length).clamp(offset, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset, end));
  }

  @override
  Future<Uint8List> readAll() async {
    readAllCount++;
    return Uint8List.fromList(bytes);
  }
}

Uint8List _minimalLeTiff(Uint8List embeddedJpeg) {
  const jpegOffset = 38;
  final buf = Uint8List(jpegOffset + embeddedJpeg.length);
  buf[0] = 0x49;
  buf[1] = 0x49;
  buf[2] = 0x2A;
  buf[4] = 8;
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
