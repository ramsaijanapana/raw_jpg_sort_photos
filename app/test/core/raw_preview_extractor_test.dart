import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/raw_preview/raw_preview_extractor.dart';

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
}
