import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/cull_session.dart';
import 'package:photo_sorter/core/exporter.dart';
import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/core/models.dart';

void main() {
  test(
    'planner exports only kept RAW and JPG when JPGs are included',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('export_plan_jpg_');
      addTearDown(() => sandbox.delete(recursive: true));
      final source = Directory(p.join(sandbox.path, 'source'));
      final destination = Directory(p.join(sandbox.path, 'destination'));
      await source.create();

      Future<File> photo(String name) async {
        final file = File(p.join(source.path, name));
        await file.writeAsString(name);
        return file;
      }

      final keptRaw = await photo('kept.arw');
      final keptJpg = await photo('kept.jpg');
      final skippedRaw = await photo('skipped.nef');
      final skippedJpg = await photo('skipped.jpeg');
      final undecidedRaw = await photo('undecided.cr2');

      final plan = await planKeptPhotoExport(
        destination: DartFileProviderSelection.fromPath(destination.path),
        pairs: [
          KeptPhotoExportSelection(
            stem: 'kept',
            raw: DartFileProviderSelection.fromPath(keptRaw.path),
            jpg: DartFileProviderSelection.fromPath(keptJpg.path),
          ),
          KeptPhotoExportSelection(
            stem: 'skipped',
            raw: DartFileProviderSelection.fromPath(skippedRaw.path),
            jpg: DartFileProviderSelection.fromPath(skippedJpg.path),
          ),
          KeptPhotoExportSelection(
            stem: 'undecided',
            raw: DartFileProviderSelection.fromPath(undecidedRaw.path),
          ),
        ],
        session: CullSession({'kept': CullFlag.keep, 'skipped': CullFlag.skip}),
        includeJpgs: true,
      );

      expect(plan.operations, hasLength(2));
      expect(
        plan.operations.map((operation) => operation.destination.opaqueItem),
        [
          p.join(destination.path, 'kept.arw'),
          p.join(destination.path, 'kept.jpg'),
        ],
      );
      expect(
        plan.operations.map((operation) => operation.intent),
        everyElement(FileOperationIntent.copy),
      );
      expect(
        plan.operations.map((operation) => operation.preview.source.label),
        ['kept.arw', 'kept.jpg'],
      );
      expect(
        plan.operations.map((operation) => operation.preview.destination.label),
        ['destination/kept.arw', 'destination/kept.jpg'],
      );
      expect(
        plan.operations.every(
          (operation) =>
              !operation.preview.source.label.contains(sandbox.path) &&
              !operation.preview.destination.label.contains(sandbox.path),
        ),
        isTrue,
      );
      expect(await destination.exists(), isFalse);
    },
  );

  test('planner excludes JPGs and supports kept RAW-only pairs', () async {
    final sandbox = await Directory.systemTemp.createTemp('export_plan_raw_');
    addTearDown(() => sandbox.delete(recursive: true));
    final source = Directory(p.join(sandbox.path, 'source'));
    final destination = Directory(p.join(sandbox.path, 'destination'));
    await source.create();
    final firstRaw = File(p.join(source.path, 'first.arw'));
    final firstJpg = File(p.join(source.path, 'first.jpg'));
    final rawOnly = File(p.join(source.path, 'raw_only.raf'));
    await firstRaw.writeAsString('first raw');
    await firstJpg.writeAsString('first jpg');
    await rawOnly.writeAsString('raw only');

    final plan = await planKeptPhotoExport(
      destination: DartFileProviderSelection.fromPath(destination.path),
      pairs: [
        KeptPhotoExportSelection(
          stem: 'first',
          raw: DartFileProviderSelection.fromPath(firstRaw.path),
          jpg: DartFileProviderSelection.fromPath(firstJpg.path),
        ),
        KeptPhotoExportSelection(
          stem: 'raw_only',
          raw: DartFileProviderSelection.fromPath(rawOnly.path),
        ),
      ],
      session: CullSession({'first': CullFlag.keep, 'raw_only': CullFlag.keep}),
      includeJpgs: false,
    );

    expect(
      plan.operations.map((operation) => operation.destination.opaqueItem),
      [
        p.join(destination.path, 'first.arw'),
        p.join(destination.path, 'raw_only.raf'),
      ],
    );
    expect(
      plan.operations.map((operation) => operation.preview.destination.label),
      ['destination/first.arw', 'destination/raw_only.raf'],
    );
    expect(await destination.exists(), isFalse);
  });

  test('planner returns an empty plan when no photo is kept', () async {
    final sandbox = await Directory.systemTemp.createTemp('export_plan_empty_');
    addTearDown(() => sandbox.delete(recursive: true));
    final source = File(p.join(sandbox.path, 'photo.arw'));
    final destination = Directory(p.join(sandbox.path, 'destination'));
    await source.writeAsString('raw');

    final plan = await planKeptPhotoExport(
      destination: DartFileProviderSelection.fromPath(destination.path),
      pairs: [
        KeptPhotoExportSelection(
          stem: 'photo',
          raw: DartFileProviderSelection.fromPath(source.path),
        ),
      ],
      session: CullSession({'photo': CullFlag.skip}),
      includeJpgs: true,
    );

    expect(plan.operations, isEmpty);
    expect(await destination.exists(), isFalse);
  });

  test(
    'legacy exporter fails closed before creating or replacing anything',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('exporter_safe_');
      try {
        final sourceDirectory = Directory(p.join(sandbox.path, 'source'));
        final destination = Directory(p.join(sandbox.path, 'destination'));
        final source = File(p.join(sourceDirectory.path, 'photo.arw'));
        await source.parent.create(recursive: true);
        await source.writeAsString('source');

        await expectLater(
          exportKept(
            source: sourceDirectory,
            destination: destination,
            pairs: [PhotoPair(stem: 'photo', raw: source)],
            session: CullSession({'photo': CullFlag.keep}),
            includeJpgs: false,
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('Task 3B'),
            ),
          ),
        );

        expect(await source.readAsString(), 'source');
        expect(await destination.exists(), isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    },
  );
}
