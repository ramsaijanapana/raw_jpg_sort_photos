import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/raw_preview/tiff_ifd.dart';

/// Builds a minimal little-endian TIFF with IFD0 containing a
/// JPEGInterchangeFormat/Length pointing to a fake embedded JPEG.
///
/// Layout:
///   0-1:   'II' (little-endian)
///   2-3:   42 (magic)
///   4-7:   offset to IFD0 = 8
///   8-9:   entry count = 2
///   10-21: tag 0x0201, type LONG (4), count 1, value = jpegOffset
///   22-33: tag 0x0202, type LONG (4), count 1, value = jpegLength
///   34-37: next IFD offset = 0
///   jpegOffset..: fake JPEG bytes
Uint8List buildMinimalTiff({required bool littleEndian, required Uint8List embeddedJpeg}) {
  // IFD starts at offset 8
  // 2 entries * 12 bytes each = 24 bytes
  // next-IFD pointer = 4 bytes
  // Total header = 8 + 2 + 24 + 4 = 38 bytes
  final ifdStart = 8;
  final ifdEntryCount = 2;
  final ifdEntriesSize = ifdEntryCount * 12;
  final nextIfdOffset = ifdStart + 2 + ifdEntriesSize;
  final jpegOffset = nextIfdOffset + 4;
  final totalSize = jpegOffset + embeddedJpeg.length;

  final buf = Uint8List(totalSize);

  void writeU16(int offset, int value) {
    if (littleEndian) {
      buf[offset] = value & 0xFF;
      buf[offset + 1] = (value >> 8) & 0xFF;
    } else {
      buf[offset] = (value >> 8) & 0xFF;
      buf[offset + 1] = value & 0xFF;
    }
  }

  void writeU32(int offset, int value) {
    if (littleEndian) {
      buf[offset] = value & 0xFF;
      buf[offset + 1] = (value >> 8) & 0xFF;
      buf[offset + 2] = (value >> 16) & 0xFF;
      buf[offset + 3] = (value >> 24) & 0xFF;
    } else {
      buf[offset] = (value >> 24) & 0xFF;
      buf[offset + 1] = (value >> 16) & 0xFF;
      buf[offset + 2] = (value >> 8) & 0xFF;
      buf[offset + 3] = value & 0xFF;
    }
  }

  // TIFF header
  buf[0] = littleEndian ? 0x49 : 0x4D; // 'I' or 'M'
  buf[1] = littleEndian ? 0x49 : 0x4D;
  writeU16(2, 42); // magic
  writeU32(4, ifdStart); // IFD0 offset

  // IFD0
  writeU16(ifdStart, ifdEntryCount);

  // Entry 0: tag 0x0201 (JPEGInterchangeFormat), type 4 (LONG), count 1, value = jpegOffset
  final e0 = ifdStart + 2;
  writeU16(e0, 0x0201);
  writeU16(e0 + 2, 4); // LONG
  writeU32(e0 + 4, 1); // count
  writeU32(e0 + 8, jpegOffset); // value = offset

  // Entry 1: tag 0x0202 (JPEGInterchangeFormatLength), type 4 (LONG), count 1, value = jpegLength
  final e1 = ifdStart + 2 + 12;
  writeU16(e1, 0x0202);
  writeU16(e1 + 2, 4); // LONG
  writeU32(e1 + 4, 1); // count
  writeU32(e1 + 8, embeddedJpeg.length); // value = length

  // next-IFD pointer = 0
  writeU32(nextIfdOffset, 0);

  // Embed the JPEG
  buf.setRange(jpegOffset, jpegOffset + embeddedJpeg.length, embeddedJpeg);

  return buf;
}

Uint8List fakeJpeg({int size = 200}) {
  final buf = Uint8List(size);
  buf[0] = 0xFF; buf[1] = 0xD8; buf[2] = 0xFF;
  buf[size - 2] = 0xFF; buf[size - 1] = 0xD9;
  return buf;
}

void main() {
  group('extractTiffPreview', () {
    test('returns null for empty buffer', () {
      expect(extractTiffPreview(Uint8List(0)), isNull);
    });

    test('returns null for non-TIFF data', () {
      final buf = Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
      expect(extractTiffPreview(buf), isNull);
    });

    test('returns null for malformed (truncated) TIFF without throwing', () {
      // Valid 'II' header but truncated at 6 bytes
      final buf = Uint8List.fromList([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00]);
      expect(() => extractTiffPreview(buf), returnsNormally);
      expect(extractTiffPreview(buf), isNull);
    });

    test('extracts JPEG from little-endian TIFF (0x0201/0x0202)', () {
      final jpeg = fakeJpeg(size: 500);
      final tiff = buildMinimalTiff(littleEndian: true, embeddedJpeg: jpeg);

      final result = extractTiffPreview(tiff);
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
      expect(result[result.length - 2], 0xFF);
      expect(result[result.length - 1], 0xD9);
    });

    test('extracts JPEG from big-endian TIFF (0x0201/0x0202)', () {
      final jpeg = fakeJpeg(size: 500);
      final tiff = buildMinimalTiff(littleEndian: false, embeddedJpeg: jpeg);

      final result = extractTiffPreview(tiff);
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
    });

    test('extracted JPEG has correct size', () {
      final jpeg = fakeJpeg(size: 1234);
      final tiff = buildMinimalTiff(littleEndian: true, embeddedJpeg: jpeg);

      final result = extractTiffPreview(tiff);
      expect(result, isNotNull);
      expect(result!.length, 1234);
    });

    test('returns null for TIFF with zero-offset JPEG entry', () {
      // Build TIFF where jpegOffset points to offset 0 (invalid)
      final buf = Uint8List(100);
      buf[0] = 0x49; buf[1] = 0x49; // 'II'
      buf[2] = 0x2A; buf[3] = 0x00; // magic 42 LE
      buf[4] = 0x08; buf[5] = 0x00; buf[6] = 0x00; buf[7] = 0x00; // IFD at 8
      buf[8] = 0x01; buf[9] = 0x00; // 1 entry
      // Entry: tag 0x0201, type LONG, count 1, value 0 (invalid offset)
      buf[10] = 0x01; buf[11] = 0x02; // tag 0x0201 LE
      buf[12] = 0x04; buf[13] = 0x00; // LONG
      buf[14] = 0x01; // count LE
      buf[18] = 0x00; // value = 0 (null offset)
      buf[22] = 0x00; // next IFD = 0

      // Should return null, not throw
      expect(() => extractTiffPreview(buf), returnsNormally);
    });

    test('never throws on any malformed structure', () {
      // Random bytes that look like TIFF header but are garbage
      for (int len in [8, 16, 32, 64, 128]) {
        final buf = Uint8List(len);
        buf[0] = 0x49; buf[1] = 0x49;
        // Random garbage for the rest
        for (int i = 2; i < len; i++) {
          buf[i] = (i * 37) % 256;
        }
        expect(() => extractTiffPreview(buf), returnsNormally);
      }
    });
  });
}
