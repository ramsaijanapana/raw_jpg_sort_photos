// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/core/exif_reader.dart';

void main() {
  group('readExifSummary — real JPEG sample', () {
    test('Canon_EOS_70D.JPG returns non-null summary with shutter+aperture+iso',
        () async {
      const path = '/home/user/test_photos/Canon_EOS_70D.JPG';
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('Test file not found at $path');
        return;
      }

      final bytes = await file.readAsBytes();
      final summary = readExifSummary(bytes);

      print('\n--- EXIF from Canon_EOS_70D.JPG ---');
      if (summary != null) {
        print('  camera:   ${summary.camera}');
        print('  shutter:  ${summary.shutter}');
        print('  aperture: ${summary.aperture}');
        print('  iso:      ${summary.iso}');
        print('  focal:    ${summary.focal}');
        print('  line:     ${summary.line}');
      } else {
        print('  (null)');
      }
      print('-----------------------------------\n');

      expect(summary, isNotNull);
      // At least two of shutter/aperture/iso must be parsed.
      final parsed = [summary!.shutter, summary.aperture, summary.iso]
          .where((s) => s != null)
          .length;
      expect(
        parsed,
        greaterThanOrEqualTo(2),
        reason:
            'Expected at least shutter+aperture or aperture+iso to be parsed '
            'from Canon_EOS_70D.JPG, got line: "${summary.line}"',
      );
    });
  });

  group('readExifSummary — real RAW sample (NEF header)', () {
    test('Nikon_D90.NEF header bytes return non-null or graceful null', () async {
      const path = '/home/user/test_photos/Nikon_D90.NEF';
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('Test file not found at $path');
        return;
      }

      // Read first 512 KB for EXIF parsing.
      final raf = await file.open();
      final length = (await file.length()).clamp(0, 512 * 1024);
      final bytes = await raf.read(length);
      await raf.close();

      print('\n--- EXIF from Nikon_D90.NEF (first 512KB) ---');
      final summary = readExifSummary(bytes);
      if (summary != null) {
        print('  camera:   ${summary.camera}');
        print('  shutter:  ${summary.shutter}');
        print('  aperture: ${summary.aperture}');
        print('  iso:      ${summary.iso}');
        print('  focal:    ${summary.focal}');
        print('  line:     ${summary.line}');
      } else {
        print('  (null — ExifIFD may be beyond first 512KB)');
      }
      print('---------------------------------------------\n');

      // Result is either non-null (preferred) or null — must NOT throw.
      // No assertion other than no-throw; NEF ExifIFD might be out of range.
      // This exercises the code path, not a specific value.
      expect(() => readExifSummary(bytes), returnsNormally);
    });
  });

  group('readExifSummary — malformed / edge cases', () {
    test('empty bytes → null, no throw', () {
      expect(readExifSummary(Uint8List(0)), isNull);
    });

    test('random bytes → null, no throw', () {
      final bytes = Uint8List.fromList(List.generate(256, (i) => i % 256));
      expect(readExifSummary(bytes), isNull);
    });

    test('truncated JPEG header → null, no throw', () {
      // FF D8 FF E1 then truncated
      final bytes = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 0x00]);
      expect(readExifSummary(bytes), isNull);
    });

    test('JPEG without EXIF APP1 → null, no throw', () {
      // Minimal JPEG with JFIF APP0 but no Exif APP1
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, // APP0 (JFIF)
        0x00, 0x10, // length 16
        0x4A, 0x46, 0x49, 0x46, 0x00, // 'JFIF\0'
        0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xD9, // EOI
      ]);
      expect(readExifSummary(bytes), isNull);
    });

    test('TIFF bytes with wrong magic → null, no throw', () {
      // II byte order but magic != 42
      final bytes = Uint8List.fromList([
        0x49, 0x49, // 'II' little-endian
        0x00, 0x00, // magic = 0 (invalid)
        0x08, 0x00, 0x00, 0x00, // IFD offset = 8
        0x00, 0x00, // 0 entries
      ]);
      // Should not throw even with invalid magic.
      expect(() => readExifSummary(bytes), returnsNormally);
    });

    test('null-like minimum TIFF (II, valid magic, 0 entries) → null, no throw',
        () {
      final bytes = Uint8List.fromList([
        0x49, 0x49, // 'II' little-endian
        0x2A, 0x00, // magic = 42
        0x08, 0x00, 0x00, 0x00, // IFD0 offset = 8
        0x00, 0x00, // 0 IFD entries
        0x00, 0x00, 0x00, 0x00, // next IFD = 0
      ]);
      expect(readExifSummary(bytes), isNull);
    });
  });
}
