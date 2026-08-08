import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/core/sorter.dart';
import 'package:photo_sorter/state/file_operation_workflow.dart';

import 'support/controlled_file_operation_platform.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('workflow_state_');
  });

  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  Future<FileOperationPlan> planSort({
    required Directory input,
    required Directory output,
  }) {
    return planSortPhotos(
      input: DartFileProviderSelection.fromPath(input.path),
      output: DartFileProviderSelection.fromPath(output.path),
    );
  }

  ProviderContainer previewOnlyContainer() {
    return ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          const FileOperationBackend(
            platform: DartFileOperationPlatform(),
            canExecute: false,
            unavailableMessage:
                'This version can preview file changes but cannot apply them '
                'yet. No files were changed.',
          ),
        ),
      ],
    );
  }

  ProviderContainer availableContainer(
    ControlledFileOperationPlatform platform,
  ) {
    return ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: true,
            unavailableMessage: 'Unavailable test backend.',
          ),
        ),
      ],
    );
  }

  Future<FileOperationPlan> controlledPlan(
    ControlledFileOperationPlatform platform,
    List<({String source, String destination, FileOperationIntent intent})>
    descriptions,
  ) {
    return planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        final operations = <FileOperation>[];
        for (final description in descriptions) {
          operations.add(
            FileOperation.create(
              source: await platform.resolveFile(
                access,
                platform.selection(
                  description.source,
                  previewComponents: ['Input', description.source],
                ),
              ),
              destination: await platform.resolveFile(
                access,
                platform.selection(
                  description.destination,
                  previewComponents: ['Output', description.destination],
                ),
              ),
              intent: description.intent,
            ),
          );
        }
        return operations;
      },
    );
  }

  test(
    'preview-only backend cannot confirm or mutate an executable plan',
    () async {
      final input = Directory(p.join(sandbox.path, 'input'))..createSync();
      final output = Directory(p.join(sandbox.path, 'output'))..createSync();
      final source = File(p.join(input.path, 'photo.arw'))
        ..writeAsStringSync('source');
      final container = previewOnlyContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        sortFileOperationWorkflowProvider.notifier,
      );

      await controller.prepare((_) => planSort(input: input, output: output));

      var state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.preview);
      expect(state.executableCount, 1);
      expect(state.executionAvailable, isFalse);

      await controller.confirm();

      state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.preview);
      expect(
        state.message,
        'This version can preview file changes but cannot apply them yet. '
        'No files were changed.',
      );
      expect(source.readAsStringSync(), 'source');
      expect(Directory(p.join(output.path, 'RAW')).existsSync(), isFalse);
    },
  );

  test(
    'empty and all-blocked previews have no executable operations',
    () async {
      final input = Directory(p.join(sandbox.path, 'input'))..createSync();
      final output = Directory(p.join(sandbox.path, 'output'))..createSync();
      final container = previewOnlyContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        sortFileOperationWorkflowProvider.notifier,
      );

      await controller.prepare((_) => planSort(input: input, output: output));
      var state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.preview);
      expect(state.plan!.operations, isEmpty);
      expect(state.executableCount, 0);
      expect(state.canConfirm, isFalse);

      File(p.join(input.path, 'photo.arw')).writeAsStringSync('source');
      final blocked = File(p.join(output.path, 'RAW', 'photo.arw'));
      blocked.parent.createSync(recursive: true);
      blocked.writeAsStringSync('existing');
      await controller.prepare((_) => planSort(input: input, output: output));
      state = container.read(sortFileOperationWorkflowProvider);
      expect(state.plan!.operations, hasLength(1));
      expect(
        state.plan!.operations.single.preflightStatus,
        FileOperationStatus.skippedConflict,
      );
      expect(state.executableCount, 0);
      expect(state.blockedCount, 1);
      expect(state.canConfirm, isFalse);

      await controller.confirm();
      expect(
        container.read(sortFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.preview,
      );
      expect(blocked.readAsStringSync(), 'existing');
    },
  );

  test(
    'planning failures publish closed text without exception path leakage',
    () async {
      final container = previewOnlyContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        sortFileOperationWorkflowProvider.notifier,
      );

      await controller.prepare(
        (_) async => throw StateError('/private/opaque/SENTINEL-PATH'),
      );

      final state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.error);
      expect(
        state.message,
        'Could not prepare a file preview. No files were changed.',
      );
      expect(state.message, isNot(contains('SENTINEL-PATH')));
      expect(state.message, isNot(contains('/private/opaque')));
    },
  );

  test('discard and planning cancellation invalidate a late plan', () async {
    final input = Directory(p.join(sandbox.path, 'input'))..createSync();
    final output = Directory(p.join(sandbox.path, 'output'))..createSync();
    File(p.join(input.path, 'photo.arw')).writeAsStringSync('source');
    final plan = await planSort(input: input, output: output);
    final container = previewOnlyContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      sortFileOperationWorkflowProvider.notifier,
    );

    for (final invalidate in <void Function()>[
      controller.discard,
      controller.cancel,
    ]) {
      final pendingPlan = Completer<FileOperationPlan>();
      final preparation = controller.prepare((_) => pendingPlan.future);
      expect(
        container.read(sortFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.planning,
      );

      invalidate();
      pendingPlan.complete(plan);
      await preparation;

      final state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.idle);
      expect(state.plan, isNull);
    }
  });

  test(
    'newer preparation cannot be overwritten by an older completion',
    () async {
      final firstInput = Directory(p.join(sandbox.path, 'first-input'))
        ..createSync();
      final secondInput = Directory(p.join(sandbox.path, 'second-input'))
        ..createSync();
      final output = Directory(p.join(sandbox.path, 'output'))..createSync();
      File(p.join(firstInput.path, 'first.arw')).writeAsStringSync('first');
      File(p.join(secondInput.path, 'second.arw')).writeAsStringSync('second');
      File(p.join(secondInput.path, 'third.jpg')).writeAsStringSync('third');
      final olderPlan = await planSort(input: firstInput, output: output);
      final newerPlan = await planSort(input: secondInput, output: output);
      final olderCompletion = Completer<FileOperationPlan>();
      final container = previewOnlyContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        sortFileOperationWorkflowProvider.notifier,
      );

      final olderPreparation = controller.prepare(
        (_) => olderCompletion.future,
      );
      await controller.prepare((_) async => newerPlan);
      olderCompletion.complete(olderPlan);
      await olderPreparation;

      final state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.preview);
      expect(state.plan, same(newerPlan));
      expect(state.plan!.operations, hasLength(2));
    },
  );

  test('provider disposal suppresses late planning publication', () async {
    final input = Directory(p.join(sandbox.path, 'input'))..createSync();
    final output = Directory(p.join(sandbox.path, 'output'))..createSync();
    File(p.join(input.path, 'photo.arw')).writeAsStringSync('source');
    final plan = await planSort(input: input, output: output);
    final pendingPlan = Completer<FileOperationPlan>();
    final container = previewOnlyContainer();
    final controller = container.read(
      sortFileOperationWorkflowProvider.notifier,
    );
    final preparation = controller.prepare((_) => pendingPlan.future);

    container.dispose();
    pendingPlan.complete(plan);

    await expectLater(preparation, completes);
  });

  test('rapid double confirmation executes one exact approval once', () async {
    final platform = ControlledFileOperationPlatform()
      ..addFile('source.arw', 'source');
    final container = availableContainer(platform);
    addTearDown(container.dispose);
    final controller = container.read(
      sortFileOperationWorkflowProvider.notifier,
    );
    await controller.prepare(
      (_) => controlledPlan(platform, [
        (
          source: 'source.arw',
          destination: 'destination.arw',
          intent: FileOperationIntent.copy,
        ),
      ]),
    );

    final first = controller.confirm();
    final second = controller.confirm();
    await Future.wait([first, second]);

    final state = container.read(sortFileOperationWorkflowProvider);
    expect(state.phase, FileOperationWorkflowPhase.completed);
    expect(state.completed, 1);
    expect(state.total, 1);
    expect(state.reportedResults, hasLength(1));
    expect(state.reportedResults.single.status, FileOperationStatus.copied);
    expect(platform.beginOperationCount, 1);
    expect(platform.exclusiveCopyCount, 1);
    expect(platform.contents('destination.arw'), 'source');
  });

  test(
    'progress publication drives cancellation and reports the remainder',
    () async {
      final platform = ControlledFileOperationPlatform()
        ..addFile('first.arw', 'first')
        ..addFile('second.arw', 'second')
        ..addFile('third.arw', 'third');
      final container = availableContainer(platform);
      addTearDown(container.dispose);
      final controller = container.read(
        sortFileOperationWorkflowProvider.notifier,
      );
      await controller.prepare(
        (_) => controlledPlan(platform, [
          for (final name in ['first', 'second', 'third'])
            (
              source: '$name.arw',
              destination: 'sorted-$name.arw',
              intent: FileOperationIntent.copy,
            ),
        ]),
      );
      var progressResultsWereImmutable = false;
      final subscription = container.listen(sortFileOperationWorkflowProvider, (
        previous,
        next,
      ) {
        if (next.phase == FileOperationWorkflowPhase.executing &&
            next.completed == 1) {
          try {
            next.reportedResults.add(next.reportedResults.single);
          } on UnsupportedError {
            progressResultsWereImmutable = true;
          }
          controller.cancel();
        }
      });
      addTearDown(subscription.close);

      await controller.confirm();

      final state = container.read(sortFileOperationWorkflowProvider);
      expect(state.phase, FileOperationWorkflowPhase.cancelled);
      expect(state.completed, 3);
      expect(state.total, 3);
      expect(state.reportedResults.map((result) => result.status), [
        FileOperationStatus.copied,
        FileOperationStatus.cancelled,
        FileOperationStatus.cancelled,
      ]);
      expect(platform.beginOperationCount, 1);
      expect(platform.contains('sorted-first.arw'), isTrue);
      expect(platform.contains('sorted-second.arw'), isFalse);
      expect(platform.contains('sorted-third.arw'), isFalse);
      expect(progressResultsWereImmutable, isTrue);
    },
  );

  test(
    'capability and hostile backend failures remain structured and closed',
    () async {
      for (final platform in [
        ControlledFileOperationPlatform(
          capabilityFailure: FileOperationStatus.accessDenied,
        ),
        ControlledFileOperationPlatform(
          capabilityError: StateError('/private/opaque/SENTINEL-BACKEND'),
        ),
      ]) {
        platform.addFile('source.arw', 'source');
        final container = availableContainer(platform);
        final controller = container.read(
          sortFileOperationWorkflowProvider.notifier,
        );
        await controller.prepare(
          (_) => controlledPlan(platform, [
            (
              source: 'source.arw',
              destination: 'destination.arw',
              intent: FileOperationIntent.copy,
            ),
          ]),
        );

        await controller.confirm();

        final state = container.read(sortFileOperationWorkflowProvider);
        expect(state.phase, FileOperationWorkflowPhase.completed);
        expect(state.reportedResults, hasLength(1));
        expect(
          state.reportedResults.single.status,
          anyOf(FileOperationStatus.accessDenied, FileOperationStatus.failed),
        );
        expect(state.message, isNot(contains('SENTINEL-BACKEND')));
        expect(state.message, isNot(contains('/private/opaque')));
        expect(platform.contains('destination.arw'), isFalse);
        container.dispose();
      }
    },
  );

  test(
    'temporary cleanup recovery is result-bound and single-flight',
    () async {
      final cleanupGate = Completer<void>();
      final platform = ControlledFileOperationPlatform(
        temporaryCopyFailure: true,
        retainTemporaryOnInitialCleanup: true,
        cleanupGate: cleanupGate,
      )..addFile('source.arw', 'source');
      final container = availableContainer(platform);
      addTearDown(container.dispose);
      final controller = container.read(
        sortFileOperationWorkflowProvider.notifier,
      );
      await controller.prepare(
        (_) => controlledPlan(platform, [
          (
            source: 'source.arw',
            destination: 'destination.arw',
            intent: FileOperationIntent.move,
          ),
        ]),
      );
      await controller.confirm();
      final original = container
          .read(sortFileOperationWorkflowProvider)
          .execution!
          .results
          .single;
      expect(original.effects.temporary, FileOperationTemporaryState.mayRemain);
      expect(platform.cleanupCount, 1);

      final firstRecovery = controller.recoverTemporary(original);
      final duplicateRecovery = controller.recoverTemporary(original);
      await platform.recoveryCleanupStarted.future;
      expect(
        container.read(sortFileOperationWorkflowProvider).cleanupOperationId,
        original.operation.id,
      );
      cleanupGate.complete();
      await Future.wait([firstRecovery, duplicateRecovery]);

      final recovered = container
          .read(sortFileOperationWorkflowProvider)
          .execution!
          .results
          .single;
      expect(platform.cleanupCount, 2);
      expect(recovered.effects.temporary, FileOperationTemporaryState.cleaned);
      expect(recovered.effects.temporaryArtifact, isNull);
      expect(
        container.read(sortFileOperationWorkflowProvider).cleanupOperationId,
        isNull,
      );
    },
  );

  test('prepare and discard cannot hide an execution in flight', () async {
    final mutationGate = Completer<void>();
    final platform = ControlledFileOperationPlatform(mutationGate: mutationGate)
      ..addFile('old-source.arw', 'old')
      ..addFile('second-source.arw', 'second')
      ..addFile('new-source.arw', 'new');
    final container = availableContainer(platform);
    addTearDown(container.dispose);
    final controller = container.read(
      sortFileOperationWorkflowProvider.notifier,
    );
    await controller.prepare(
      (_) => controlledPlan(platform, [
        (
          source: 'old-source.arw',
          destination: 'old-destination.arw',
          intent: FileOperationIntent.copy,
        ),
        (
          source: 'second-source.arw',
          destination: 'second-destination.arw',
          intent: FileOperationIntent.copy,
        ),
      ]),
    );
    final oldExecution = controller.confirm();
    await platform.mutationStarted.future;

    controller.discard();
    var attemptedBuilderCalls = 0;
    await controller.prepare((_) {
      attemptedBuilderCalls++;
      return controlledPlan(platform, [
        (
          source: 'new-source.arw',
          destination: 'new-destination.arw',
          intent: FileOperationIntent.copy,
        ),
      ]);
    });
    var state = container.read(sortFileOperationWorkflowProvider);
    expect(state.phase, FileOperationWorkflowPhase.executing);
    expect(state.message, 'Stopping safely after the current file…');
    expect(attemptedBuilderCalls, 0);

    mutationGate.complete();
    await oldExecution;

    state = container.read(sortFileOperationWorkflowProvider);
    expect(state.phase, FileOperationWorkflowPhase.cancelled);
    expect(state.reportedResults.map((result) => result.status), [
      FileOperationStatus.copied,
      FileOperationStatus.cancelled,
    ]);
    controller.discard();
    expect(
      container.read(sortFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.idle,
    );
  });

  test('provider disposal suppresses late execution publication', () async {
    final mutationGate = Completer<void>();
    final platform = ControlledFileOperationPlatform(mutationGate: mutationGate)
      ..addFile('source.arw', 'source');
    final container = availableContainer(platform);
    final controller = container.read(
      sortFileOperationWorkflowProvider.notifier,
    );
    await controller.prepare(
      (_) => controlledPlan(platform, [
        (
          source: 'source.arw',
          destination: 'destination.arw',
          intent: FileOperationIntent.copy,
        ),
      ]),
    );
    final execution = controller.confirm();
    await platform.mutationStarted.future;

    container.dispose();
    mutationGate.complete();

    await expectLater(execution, completes);
  });

  test('prepare and discard cannot hide cleanup recovery in flight', () async {
    final cleanupGate = Completer<void>();
    final platform =
        ControlledFileOperationPlatform(
            temporaryCopyFailure: true,
            retainTemporaryOnInitialCleanup: true,
            cleanupGate: cleanupGate,
          )
          ..addFile('old-source.arw', 'old')
          ..addFile('new-source.arw', 'new');
    final container = availableContainer(platform);
    addTearDown(container.dispose);
    final controller = container.read(
      sortFileOperationWorkflowProvider.notifier,
    );
    await controller.prepare(
      (_) => controlledPlan(platform, [
        (
          source: 'old-source.arw',
          destination: 'old-destination.arw',
          intent: FileOperationIntent.move,
        ),
      ]),
    );
    await controller.confirm();
    final oldResult = container
        .read(sortFileOperationWorkflowProvider)
        .execution!
        .results
        .single;
    final recovery = controller.recoverTemporary(oldResult);
    await platform.recoveryCleanupStarted.future;

    controller.discard();
    var attemptedBuilderCalls = 0;
    await controller.prepare((_) {
      attemptedBuilderCalls++;
      return controlledPlan(platform, [
        (
          source: 'new-source.arw',
          destination: 'new-destination.arw',
          intent: FileOperationIntent.copy,
        ),
      ]);
    });
    var state = container.read(sortFileOperationWorkflowProvider);
    expect(state.phase, FileOperationWorkflowPhase.completed);
    expect(state.execution, isNotNull);
    expect(state.cleanupOperationId, oldResult.operation.id);
    expect(attemptedBuilderCalls, 0);

    cleanupGate.complete();
    await recovery;
    await controller.recoverTemporary(oldResult);

    state = container.read(sortFileOperationWorkflowProvider);
    expect(state.phase, FileOperationWorkflowPhase.completed);
    expect(
      state.execution!.results.single.effects.temporary,
      FileOperationTemporaryState.cleaned,
    );
    expect(state.cleanupOperationId, isNull);
    expect(platform.cleanupCount, 2);

    controller.discard();
    await controller.prepare(
      (_) => controlledPlan(platform, [
        (
          source: 'new-source.arw',
          destination: 'new-destination.arw',
          intent: FileOperationIntent.copy,
        ),
      ]),
    );
    expect(
      container.read(sortFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.preview,
    );
  });
}
