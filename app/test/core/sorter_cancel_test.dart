import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/sorter.dart';

void main() {
  test(
    'legacy cancellation callback cannot authorize direct mutation',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'sorter_cancel_safe_',
      );
      try {
        final source = File(p.join(sandbox.path, 'photo.arw'));
        await source.writeAsString('source');
        var cancellationChecks = 0;

        await expectLater(
          sortPhotos(
            input: sandbox,
            output: sandbox,
            shouldCancel: () {
              cancellationChecks++;
              return false;
            },
          ),
          throwsA(isA<UnsupportedError>()),
        );

        expect(cancellationChecks, 0);
        expect(await source.readAsString(), 'source');
        expect(await Directory(p.join(sandbox.path, 'RAW')).exists(), isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    },
  );

  group('SortResult.cancelled field', () {
    test('default cancelled is false', () {
      const result = SortResult(
        rawCount: 0,
        jpgCount: 0,
        skipped: 0,
        moved: false,
        outputPath: '/tmp',
      );
      expect(result.cancelled, isFalse);
    });

    test('cancelled true is preserved', () {
      const result = SortResult(
        rawCount: 1,
        jpgCount: 0,
        skipped: 0,
        moved: true,
        outputPath: '/tmp',
        cancelled: true,
      );
      expect(result.cancelled, isTrue);
    });
  });
}
