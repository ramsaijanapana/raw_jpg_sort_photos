import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/raw_preview/jpeg_scan.dart';

// Helper: build a minimal STRUCTURALLY VALID fake JPEG of given size:
// SOI + APP0 segment + SOS header + zero entropy data + EOI. The scanner
// walks marker structure, so candidates must be real JPEG skeletons.
Uint8List fakeJpeg({int size = 100}) {
  assert(size >= 16);
  final buf = Uint8List(size);
  buf.setRange(0, 2, [0xFF, 0xD8]); // SOI
  buf.setRange(2, 8, [0xFF, 0xE0, 0x00, 0x04, 0x4A, 0x46]); // APP0, len 4
  buf.setRange(8, 12, [0xFF, 0xDA, 0x00, 0x02]); // SOS, len 2
  // bytes 12 .. size-2 are zero entropy data (no FF bytes)
  buf[size - 2] = 0xFF;
  buf[size - 1] = 0xD9; // EOI
  return buf;
}

// Helper: concatenate two Uint8Lists
Uint8List concat(Uint8List a, Uint8List b) {
  final result = Uint8List(a.length + b.length);
  result.setRange(0, a.length, a);
  result.setRange(a.length, result.length, b);
  return result;
}

void main() {
  group('findLargestEmbeddedJpeg', () {
    test('returns null for empty buffer', () {
      expect(findLargestEmbeddedJpeg(Uint8List(0)), isNull);
    });

    test('returns null for buffer too small', () {
      expect(findLargestEmbeddedJpeg(Uint8List(3)), isNull);
    });

    test('returns null when no JPEG markers present', () {
      final buf = Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
      expect(findLargestEmbeddedJpeg(buf), isNull);
    });

    test('returns null for SOI without EOI', () {
      // Buffer with SOI but no EOI
      final buf = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01]);
      final result = findLargestEmbeddedJpeg(buf);
      // Should return null since there's no valid EOI
      expect(result, isNull);
    });

    test('finds a single JPEG exactly', () {
      final jpeg = fakeJpeg(size: 10000);
      final result = findLargestEmbeddedJpeg(jpeg);
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
    });

    test('finds JPEG embedded at offset with garbage around it', () {
      final garbage = Uint8List.fromList([0x00, 0x01, 0x02, 0x03, 0x04]);
      final jpeg = fakeJpeg(size: 10000);
      final trailingGarbage = Uint8List.fromList([0xAB, 0xCD]);
      final buf = concat(concat(garbage, jpeg), trailingGarbage);

      final result = findLargestEmbeddedJpeg(buf);
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
    });

    test('two JPEGs — picks the larger one', () {
      final small = fakeJpeg(size: 1000);
      final large = fakeJpeg(size: 50000);
      final buf = concat(small, large);

      final result = findLargestEmbeddedJpeg(buf, minSize: 100);
      expect(result, isNotNull);
      // Should prefer the larger JPEG
      expect(result!.length, greaterThanOrEqualTo(large.length));
    });

    test('respects minSize: returns best even if below threshold when nothing qualifies', () {
      final small = fakeJpeg(size: 500);
      // minSize is 8192, so this should still return the only option
      final result = findLargestEmbeddedJpeg(small, minSize: 8192);
      // Falls back to largest overall even if below minSize
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
    });

    test('prefers JPEG >= minSize over smaller one', () {
      final small = fakeJpeg(size: 100);
      final big = fakeJpeg(size: 20000);
      final buf = concat(small, big);

      final result = findLargestEmbeddedJpeg(buf, minSize: 8192);
      expect(result!.length, greaterThanOrEqualTo(8192));
    });

    test('result starts with FFD8 (valid JPEG header)', () {
      final jpeg = fakeJpeg(size: 10000);
      final result = findLargestEmbeddedJpeg(jpeg);
      expect(result, isNotNull);
      expect(result![0], 0xFF);
      expect(result[1], 0xD8);
    });

    test('result ends with FFD9 (valid JPEG trailer)', () {
      final jpeg = fakeJpeg(size: 10000);
      final result = findLargestEmbeddedJpeg(jpeg);
      expect(result, isNotNull);
      expect(result![result.length - 2], 0xFF);
      expect(result[result.length - 1], 0xD9);
    });

    test('truncated SOI without EOI returns null', () {
      // Just the SOI marker, no EOI anywhere
      final buf = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xE0, // SOI + APP0 start
        0x00, 0x10, // APP0 length
      ]);
      final result = findLargestEmbeddedJpeg(buf);
      expect(result, isNull);
    });
  });
}
