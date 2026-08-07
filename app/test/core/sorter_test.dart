import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/core/sorter.dart';

void main() {
  test(
    'planner routes RAW and JPG, ignores unsupported, and moves in place',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('sort_plan_same_');
      addTearDown(() => sandbox.delete(recursive: true));
      await File(p.join(sandbox.path, 'a.arw')).writeAsString('raw');
      await File(p.join(sandbox.path, 'b.jpg')).writeAsString('jpg');
      await File(p.join(sandbox.path, 'notes.txt')).writeAsString('notes');

      final selection = DartFileProviderSelection.fromPath(sandbox.path);
      final plan = await planSortPhotos(input: selection, output: selection);

      expect(plan.operations, hasLength(2));
      expect(
        plan.operations.map((operation) => operation.intent),
        everyElement(FileOperationIntent.move),
      );
      expect(
        plan.operations.map((operation) => operation.destination.opaqueItem),
        [
          p.join(sandbox.path, 'RAW', 'a.arw'),
          p.join(sandbox.path, 'JPG', 'b.jpg'),
        ],
      );
      expect(
        plan.operations.map((operation) => operation.preview.source.label),
        [
          '${p.basename(sandbox.path)}/a.arw',
          '${p.basename(sandbox.path)}/b.jpg',
        ],
      );
      expect(
        plan.operations.map((operation) => operation.preview.destination.label),
        [
          '${p.basename(sandbox.path)}/RAW/a.arw',
          '${p.basename(sandbox.path)}/JPG/b.jpg',
        ],
      );
      expect(
        plan.operations.every(
          (operation) =>
              !operation.preview.source.label.contains(sandbox.path) &&
              !operation.preview.destination.label.contains(sandbox.path),
        ),
        isTrue,
      );
      expect(await Directory(p.join(sandbox.path, 'RAW')).exists(), isFalse);
      expect(await Directory(p.join(sandbox.path, 'JPG')).exists(), isFalse);
      expect(
        await File(p.join(sandbox.path, 'notes.txt')).readAsString(),
        'notes',
      );
    },
  );

  test('planner uses copy intent for a separate destination', () async {
    final sandbox = await Directory.systemTemp.createTemp('sort_plan_copy_');
    addTearDown(() => sandbox.delete(recursive: true));
    final input = Directory(p.join(sandbox.path, 'input'));
    final output = Directory(p.join(sandbox.path, 'output'));
    await input.create();
    final source = File(p.join(input.path, 'photo.nef'));
    await source.writeAsString('raw');

    final plan = await planSortPhotos(
      input: DartFileProviderSelection.fromPath(input.path),
      output: DartFileProviderSelection.fromPath(output.path),
    );

    expect(plan.operations, hasLength(1));
    expect(plan.operations.single.intent, FileOperationIntent.copy);
    expect(
      plan.operations.single.destination.opaqueItem,
      p.join(output.path, 'RAW', 'photo.nef'),
    );
    expect(await source.readAsString(), 'raw');
    expect(await output.exists(), isFalse);
  });

  test(
    'legacy sorter fails closed before moving or creating destinations',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('sorter_safe_');
      try {
        final source = File(p.join(sandbox.path, 'photo.arw'));
        await source.writeAsString('source');

        await expectLater(
          sortPhotos(input: sandbox, output: sandbox),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('Task 3B'),
            ),
          ),
        );

        expect(await source.readAsString(), 'source');
        expect(await Directory(p.join(sandbox.path, 'RAW')).exists(), isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    },
  );

  test(
    'legacy sorter fails closed before creating a separate output',
    () async {
      final sandbox = await Directory.systemTemp.createTemp('sorter_safe_');
      try {
        final input = Directory(p.join(sandbox.path, 'input'));
        final output = Directory(p.join(sandbox.path, 'output'));
        final source = File(p.join(input.path, 'photo.jpg'));
        await source.parent.create(recursive: true);
        await source.writeAsString('source');

        await expectLater(
          sortPhotos(input: input, output: output),
          throwsA(isA<UnsupportedError>()),
        );

        expect(await source.readAsString(), 'source');
        expect(await output.exists(), isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    },
  );
}
