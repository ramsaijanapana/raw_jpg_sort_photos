import 'dart:io';
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/raw_preview/raw_preview_extractor.dart';

void main() {
  const testPhotosDir = '/home/user/test_photos';
  const supportedExtensions = {
    '.arw', '.nef', '.cr2', '.dng', '.raf', '.orf', '.rw2', '.pef', '.srw', '.cr3',
  };

  group('Real RAW file preview extraction', () {
    test('extracts JPEG previews from real RAW samples', () async {
      final dir = Directory(testPhotosDir);

      if (!dir.existsSync()) {
        // Guard: skip when directory is absent
        markTestSkipped('Test photos directory not found at $testPhotosDir — skipping real sample tests.');
        return;
      }

      final rawFiles = <File>[];
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (supportedExtensions.contains(ext)) {
            rawFiles.add(entity);
          }
        }
      }

      if (rawFiles.isEmpty) {
        markTestSkipped('No RAW files found in $testPhotosDir — skipping.');
        return;
      }

      print('\n--- Real RAW Preview Extraction Results ---');
      int successes = 0;
      int failures = 0;

      for (final file in rawFiles) {
        final name = p.basename(file.path);
        final ext = p.extension(file.path).toLowerCase();

        try {
          final bytes = await file.readAsBytes();
          final result = extractPreviewBytes(bytes, ext);

          if (result != null && result.length >= 4 && result[0] == 0xFF && result[1] == 0xD8) {
            successes++;
            print('  OK  $name  (${result.length} bytes)');
          } else {
            failures++;
            print('  FAIL $name  (result: ${result == null ? "null" : "invalid header"})');
          }
        } catch (e) {
          failures++;
          print('  ERR  $name  ($e)');
        }
      }

      final total = successes + failures;
      final successRate = total > 0 ? successes / total : 0.0;
      print('\nResult: $successes/$total extracted successfully (${(successRate * 100).toStringAsFixed(0)}%)');
      print('-------------------------------------------\n');

      // Assert at least 80% success rate
      expect(
        successRate,
        greaterThanOrEqualTo(0.8),
        reason: 'Expected at least 80% of RAW files to yield valid JPEG previews, '
            'but got $successes/$total',
      );
    });

    test('extractPreview(File) returns valid JPEG bytes for each sample', () async {
      final dir = Directory(testPhotosDir);

      if (!dir.existsSync()) {
        markTestSkipped('Test photos directory not found at $testPhotosDir — skipping.');
        return;
      }

      final rawFiles = <File>[];
      await for (final entity in dir.list(recursive: false)) {
        if (entity is File) {
          final ext = p.extension(entity.path).toLowerCase();
          if (supportedExtensions.contains(ext)) {
            rawFiles.add(entity);
          }
        }
      }

      if (rawFiles.isEmpty) {
        markTestSkipped('No RAW files found in $testPhotosDir — skipping.');
        return;
      }

      int successes = 0;
      for (final file in rawFiles) {
        final result = await extractPreview(file);
        if (result != null && result.length >= 2 && result[0] == 0xFF && result[1] == 0xD8) {
          successes++;
        }
      }

      final successRate = successes / rawFiles.length;
      expect(successRate, greaterThanOrEqualTo(0.8));
    });
  });
}
