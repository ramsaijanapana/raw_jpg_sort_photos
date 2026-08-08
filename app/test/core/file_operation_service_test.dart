import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/cull_session.dart';
import 'package:photo_sorter/core/exporter.dart';
import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/core/sorter.dart';

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('photo_file_operations_');
  });

  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  String path(String relative) => p.join(sandbox.path, relative);

  Future<File> writeFile(String relative, [String contents = 'photo']) async {
    final file = File(path(relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
    return file;
  }

  FileProviderSelection selection(String value) {
    return FileProviderSelection(
      providerIdentity: const FileProviderIdentity('controlled-provider'),
      opaqueLocator: p.normalize(value),
    );
  }

  Future<({FileOperationPlan plan, FileOperation operation})> planOne(
    _ControlledPlatform platform, {
    required String sourcePath,
    required String destinationPath,
    FileOperationIntent intent = FileOperationIntent.copy,
  }) async {
    late FileOperation operation;
    final plan = await planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        final source = await platform.resolveFile(
          access,
          selection(sourcePath),
        );
        final destination = await platform.resolveFile(
          access,
          selection(destinationPath),
        );
        operation = FileOperation.create(
          source: source,
          destination: destination,
          intent: intent,
        );
        return [operation];
      },
    );
    return (plan: plan, operation: operation);
  }

  Future<FileOperationExecution> execute(
    FileOperationPlan plan,
    FileOperationPlatform platform, {
    bool Function()? shouldCancel,
  }) {
    return executeFileOperationPlan(
      plan,
      approval: FileOperationApproval.forPlan(plan),
      platform: platform,
      shouldCancel: shouldCancel,
    );
  }

  test('planning preserves an existing destination as a conflict', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'source')
      ..addFile(path('destination/photo.arw'), 'existing');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );

    final execution = await execute(planned.plan, platform);

    expect(
      execution.results.single.status,
      FileOperationStatus.skippedConflict,
    );
    expect(platform.contents(path('destination/photo.arw')), 'existing');
    expect(platform.contents(path('source/photo.arw')), 'source');
  });

  test(
    'platform collision key governs planned and existing case collisions',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source')
        ..addFile(path('destination/PHOTO.ARW'), 'existing');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      expect(
        planned.plan.operations.single.preflightStatus,
        FileOperationStatus.skippedConflict,
      );
    },
  );

  test(
    'Dart inspection routes desired and enumerated names through override',
    () async {
      final source = await writeFile('source/photo.arw', 'source');
      await writeFile('destination/caf\u00e9.arw', 'existing');
      final desired = File(path('destination/cafe\u0301.arw'));
      const platform = _UnicodeCollisionDartPlatform();

      final plan = await planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final sourceReference = await platform.resolveFile(
            access,
            DartFileProviderSelection.fromPath(source.path),
          );
          final destinationReference = await platform.resolveFile(
            access,
            DartFileProviderSelection.fromPath(desired.path),
          );
          return [
            FileOperation.create(
              source: sourceReference,
              destination: destinationReference,
              intent: FileOperationIntent.copy,
            ),
          ];
        },
      );

      expect(
        plan.operations.single.preflightStatus,
        FileOperationStatus.skippedConflict,
      );
      expect(await source.readAsString(), 'source');
    },
  );

  test(
    'Dart planning rejects a regular file selected as a directory',
    () async {
      final source = await writeFile('source/photo.arw', 'source');
      final destination = await writeFile('export-target', 'occupied');

      await expectLater(
        planKeptPhotoExport(
          destination: DartFileProviderSelection.fromPath(destination.path),
          pairs: [
            KeptPhotoExportSelection(
              stem: 'photo',
              raw: DartFileProviderSelection.fromPath(source.path),
            ),
          ],
          session: CullSession({'photo': CullFlag.keep}),
          includeJpgs: false,
        ),
        throwsA(isA<FileOperationException>()),
      );

      expect(await destination.readAsString(), 'occupied');
      expect(await source.readAsString(), 'source');
    },
  );

  test('Dart planning conflicts when a required parent is a file', () async {
    final input = Directory(path('parent-file-input'));
    final output = Directory(path('parent-file-output'));
    await input.create();
    await output.create();
    final source = File(p.join(input.path, 'photo.arw'));
    final occupiedParent = File(p.join(output.path, 'RAW'));
    await source.writeAsString('source');
    await occupiedParent.writeAsString('occupied');

    final plan = await planSortPhotos(
      input: DartFileProviderSelection.fromPath(input.path),
      output: DartFileProviderSelection.fromPath(output.path),
    );

    expect(plan.operations, hasLength(1));
    expect(
      plan.operations.single.preflightStatus,
      FileOperationStatus.skippedConflict,
    );
    expect(await occupiedParent.readAsString(), 'occupied');
    expect(await source.readAsString(), 'source');
  });

  test(
    'Dart planning conflicts on a case-colliding intermediate directory',
    () async {
      final input = Directory(path('case-parent-input'));
      final output = Directory(path('case-parent-output'));
      final collidingParent = Directory(p.join(output.path, 'raw'));
      await input.create();
      await collidingParent.create(recursive: true);
      final source = File(p.join(input.path, 'photo.arw'));
      await source.writeAsString('source');

      final plan = await planSortPhotos(
        input: DartFileProviderSelection.fromPath(input.path),
        output: DartFileProviderSelection.fromPath(output.path),
      );

      expect(plan.operations, hasLength(1));
      expect(
        plan.operations.single.preflightStatus,
        FileOperationStatus.skippedConflict,
      );
      expect(await collidingParent.exists(), isTrue);
      expect(await source.readAsString(), 'source');
    },
  );

  test('duplicate target preserves an earlier planning access issue', () async {
    final platform =
        _ControlledPlatform(
            planningInspectionFailure: FileOperationStatus.accessDenied,
          )
          ..addFile(path('source/first.arw'), 'first')
          ..addFile(path('source/second.arw'), 'second');
    final plan = await planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        final destination = await platform.resolveFile(
          access,
          selection(path('destination/photo.arw')),
        );
        return [
          for (final sourceName in ['first.arw', 'second.arw'])
            FileOperation.create(
              source: await platform.resolveFile(
                access,
                selection(path('source/$sourceName')),
              ),
              destination: destination,
              intent: FileOperationIntent.copy,
            ),
        ];
      },
    );

    for (final operation in plan.operations) {
      expect(operation.preflightStatus, FileOperationStatus.accessDenied);
      expect(
        operation.preflightIssues.map((issue) => issue.status),
        containsAll([
          FileOperationStatus.accessDenied,
          FileOperationStatus.skippedConflict,
        ]),
      );
    }
  });

  test(
    'approval for another immutable plan is rejected before access begins',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final first = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/first.arw'),
      );
      final second = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/second.arw'),
      );

      await expectLater(
        executeFileOperationPlan(
          first.plan,
          approval: FileOperationApproval.forPlan(second.plan),
          platform: platform,
        ),
        throwsA(isA<FileOperationApprovalMismatchException>()),
      );
      expect(platform.beginCount, 0);
    },
  );

  test('approval is atomically one-shot before provider access', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );
    final approval = FileOperationApproval.forPlan(planned.plan);

    expect(
      () => planned.plan.operations.add(planned.operation),
      throwsUnsupportedError,
    );

    final first = executeFileOperationPlan(
      planned.plan,
      approval: approval,
      platform: platform,
    );
    await expectLater(
      executeFileOperationPlan(
        planned.plan,
        approval: approval,
        platform: platform,
      ),
      throwsA(isA<FileOperationApprovalConsumedException>()),
    );
    await first;

    expect(platform.beginCount, 1);
    expect(platform.endCount, 1);
  });

  test(
    'operation id is stable and resists delimiter collision vectors',
    () async {
      final sourceA = FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('provider'),
        itemIdentity: const FileProviderItemIdentity('a|b'),
        opaqueItem: 'opaque-source-a',
        itemName: null,
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated('source-a'),
        ),
      );
      final destinationA = FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('c'),
        itemIdentity: const FileProviderItemIdentity('d'),
        opaqueItem: 'opaque-destination-a',
        itemName: null,
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated('destination-a'),
        ),
      );
      final sourceB = FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('provider|a'),
        itemIdentity: const FileProviderItemIdentity('b'),
        opaqueItem: 'opaque-source-b',
        itemName: null,
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated('source-b'),
        ),
      );
      final destinationB = FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('c'),
        itemIdentity: const FileProviderItemIdentity('d'),
        opaqueItem: 'opaque-destination-b',
        itemName: null,
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated('destination-b'),
        ),
      );

      final first = stableFileOperationId(
        source: sourceA,
        destination: destinationA,
        intent: FileOperationIntent.copy,
      );
      final repeated = stableFileOperationId(
        source: sourceA,
        destination: destinationA,
        intent: FileOperationIntent.copy,
      );
      final presentationVariant = FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('provider'),
        itemIdentity: const FileProviderItemIdentity('a|b'),
        opaqueItem: 'different-opaque-source',
        itemName: null,
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated('different-presentation'),
        ),
      );
      final presentationChanged = stableFileOperationId(
        source: presentationVariant,
        destination: destinationA,
        intent: FileOperationIntent.copy,
      );
      final collisionVector = stableFileOperationId(
        source: sourceB,
        destination: destinationB,
        intent: FileOperationIntent.copy,
      );

      expect(first, repeated);
      expect(first, presentationChanged);
      expect(first, startsWith('op-v2-'));
      expect(first, isNot(collisionVector));
      expect(first, isNot(contains('opaque')));
      expect(first, isNot(contains('source-a')));
    },
  );

  test('provider exceptions reject success and contradictory statuses', () {
    for (final status in [
      FileOperationStatus.copied,
      FileOperationStatus.moved,
    ]) {
      expect(
        () => FileOperationException(status),
        throwsArgumentError,
        reason: 'general provider exception status: $status',
      );
      expect(
        () => FileOperationException.promotionNotCommitted(status),
        throwsArgumentError,
        reason: 'not-committed promotion status: $status',
      );
      expect(
        () => FileOperationException.promotionUnknown(
          status,
          temporaryConsumed: false,
        ),
        throwsArgumentError,
        reason: 'unknown promotion status: $status',
      );
      expect(
        () => FileOperationException.promotionCommitted(status),
        throwsArgumentError,
        reason: 'committed promotion status: $status',
      );
    }
    expect(
      () => FileOperationException.promotionCommitted(
        FileOperationStatus.skippedConflict,
      ),
      throwsArgumentError,
    );
    expect(
      () => FileOperationException.promotionUnknown(
        FileOperationStatus.skippedConflict,
        temporaryConsumed: false,
      ),
      throwsArgumentError,
    );
    expect(
      FileOperationException(FileOperationStatus.cancelled).status,
      FileOperationStatus.cancelled,
    );
    expect(
      FileOperationException.promotionCommitted(
        FileOperationStatus.cancelled,
      ).status,
      FileOperationStatus.cancelled,
    );
  });

  test(
    'malformed provider success statuses are normalized to failure',
    () async {
      final capabilityPlatform = _ControlledPlatform(
        capabilityReportsCopied: true,
      )..addFile(path('source/capability.arw'), 'source');
      final capabilityPlan = await planOne(
        capabilityPlatform,
        sourcePath: path('source/capability.arw'),
        destinationPath: path('destination/capability.arw'),
      );

      final capabilityResult = (await execute(
        capabilityPlan.plan,
        capabilityPlatform,
      )).results.single;

      expect(capabilityResult.status, FileOperationStatus.failed);
      expect(
        capabilityResult.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(
        capabilityPlatform.contains(path('destination/capability.arw')),
        isFalse,
      );

      final promotionPlatform = _ControlledPlatform(
        promotionReportsMovedWithoutCommit: true,
      )..addFile(path('source/promotion.arw'), 'source');
      final promotionPlan = await planOne(
        promotionPlatform,
        sourcePath: path('source/promotion.arw'),
        destinationPath: path('destination/promotion.arw'),
        intent: FileOperationIntent.move,
      );

      final promotionResult = (await execute(
        promotionPlan.plan,
        promotionPlatform,
      )).results.single;

      expect(promotionResult.status, FileOperationStatus.failed);
      expect(
        promotionResult.effects.destination,
        FileOperationDestinationState.unknown,
      );
      expect(promotionResult.effects.source, FileOperationSourceState.retained);
      expect(promotionPlatform.deleteSourceCalls, 0);
      expect(promotionPlatform.temporaryCount, 0);
    },
  );

  test(
    'misplaced consumed-promotion error cannot suppress temp cleanup',
    () async {
      final platform = _ControlledPlatform(
        tempCopyThrowsMisplacedConsumedPromotion: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final result = (await execute(planned.plan, platform)).results.single;

      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(result.effects.temporary, FileOperationTemporaryState.cleaned);
      expect(platform.temporaryCount, 0);
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
      expect(platform.endCount, 1);
    },
  );

  test(
    'destination-stage ENOENT never claims that the source is missing',
    () async {
      Future<FileOperationResult> resultFor(
        _ControlledPlatform platform, {
        FileOperationIntent intent = FileOperationIntent.copy,
      }) async {
        platform.addFile(path('source/${platform.hashCode}.arw'), 'source');
        final planned = await planOne(
          platform,
          sourcePath: path('source/${platform.hashCode}.arw'),
          destinationPath: path('destination/${platform.hashCode}.arw'),
          intent: intent,
        );
        return (await execute(planned.plan, platform)).results.single;
      }

      final results = [
        await resultFor(_ControlledPlatform(prepareEnoent: true)),
        await resultFor(
          _ControlledPlatform(promotionEnoent: true),
          intent: FileOperationIntent.move,
        ),
        await resultFor(
          _ControlledPlatform(
            interruptTemporaryCopy: true,
            tempCleanupEnoent: true,
          ),
          intent: FileOperationIntent.move,
        ),
      ];

      for (final result in results) {
        expect(result.status, FileOperationStatus.failed);
        expect(
          result.recovery.map((item) => item.action),
          isNot(contains(FileOperationRecoveryAction.reselectSource)),
        );
        expect(
          result.issues
              .where(
                (issue) =>
                    issue.stage == FileOperationStage.prepareDestination ||
                    issue.stage == FileOperationStage.promoteTemporary ||
                    issue.stage == FileOperationStage.cleanupTemporary,
              )
              .map((issue) => issue.status),
          isNot(contains(FileOperationStatus.sourceMissing)),
        );
      }
    },
  );

  test(
    'typed conflict is accepted only at a no-commit collision boundary',
    () async {
      final promotionPlatform = _ControlledPlatform(
        genericPromotionConflict: true,
      )..addFile(path('source/promotion.arw'), 'source');
      final promotionPlan = await planOne(
        promotionPlatform,
        sourcePath: path('source/promotion.arw'),
        destinationPath: path('destination/promotion.arw'),
        intent: FileOperationIntent.move,
      );

      final promotionResult = (await execute(
        promotionPlan.plan,
        promotionPlatform,
      )).results.single;

      expect(promotionResult.status, FileOperationStatus.failed);
      expect(
        promotionResult.effects.destination,
        FileOperationDestinationState.unknown,
      );
      expect(promotionResult.effects.source, FileOperationSourceState.retained);
      expect(
        promotionResult.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.chooseDifferentDestination)),
      );
      expect(promotionPlatform.deleteSourceCalls, 0);

      final deletionPlatform = _ControlledPlatform(sourceDeleteConflict: true)
        ..addFile(path('source/deletion.arw'), 'source');
      final deletionPlan = await planOne(
        deletionPlatform,
        sourcePath: path('source/deletion.arw'),
        destinationPath: path('destination/deletion.arw'),
        intent: FileOperationIntent.move,
      );

      final deletionResult = (await execute(
        deletionPlan.plan,
        deletionPlatform,
      )).results.single;

      expect(deletionResult.status, FileOperationStatus.failed);
      expect(
        deletionResult.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(deletionResult.effects.source, FileOperationSourceState.unknown);
      expect(
        deletionResult.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.chooseDifferentDestination)),
      );
      expect(
        deletionResult.recovery.map((item) => item.action),
        contains(FileOperationRecoveryAction.verifySource),
      );
    },
  );

  test(
    'typed source-missing status is accepted only at source stages',
    () async {
      final platform = _ControlledPlatform(prepareTypedSourceMissing: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final result = (await execute(planned.plan, platform)).results.single;

      expect(result.status, FileOperationStatus.failed);
      expect(
        result.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.reselectSource)),
      );
      expect(
        result.issues
            .where(
              (issue) => issue.stage == FileOperationStage.prepareDestination,
            )
            .single
            .status,
        FileOperationStatus.failed,
      );
    },
  );

  test('provider effects are ignored outside their authorized stage', () async {
    final platform = _ControlledPlatform(capabilityClaimsEffects: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );

    final result = (await execute(planned.plan, platform)).results.single;

    expect(result.status, FileOperationStatus.failed);
    expect(
      result.effects.destination,
      FileOperationDestinationState.notCommitted,
    );
    expect(result.effects.source, FileOperationSourceState.unknown);
    expect(result.effects.temporary, FileOperationTemporaryState.none);
    expect(result.effects.temporaryArtifact, isNull);
    expect(
      result.effects.destinationParent,
      FileOperationDestinationParentState.unchanged,
    );
    expect(platform.events, isNot(contains('cleanup')));
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.contains(path('destination/photo.arw')), isFalse);
  });

  test('provider destination names reject traversal and separator vectors', () {
    for (final unsafe in [
      '',
      '.',
      '..',
      '../outside.arw',
      'folder/photo.arw',
      r'folder\photo.arw',
      '/absolute.arw',
      '\u0000photo.arw',
    ]) {
      expect(
        () => FileProviderItemName.validated(unsafe),
        throwsArgumentError,
        reason: 'unsafe provider name: $unsafe',
      );
    }
    expect(FileProviderItemName.validated('photo.arw').value, 'photo.arw');
  });

  test('preview breadcrumbs visibly escape control and bidi characters', () {
    final preview = FileOperationPreviewPath.single(
      FileProviderItemName.validated('line\n\t\u202e\u2066photo.arw'),
    );

    expect(preview.label, r'line\n\t\u{202E}\u{2066}photo.arw');
    expect(preview.label, isNot(contains('\n')));
    expect(preview.label, isNot(contains('\t')));
    expect(preview.label, isNot(contains('\u202e')));
    expect(preview.label, isNot(contains('\u2066')));
  });

  test(
    'preview breadcrumbs are immutable and bound into the plan digest',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');

      Future<FileOperationPlan> planWithFolder(String folder) {
        return planFileOperations(
          platform: platform,
          buildOperations: (access) async {
            final source = await platform.resolveFile(
              access,
              selection(path('source/photo.arw')),
            );
            final destination = platform.issueReferenceForTest(
              access,
              path: path('destination/$folder/photo.arw'),
              itemIdentity: const FileProviderItemIdentity(
                'shared-destination-item',
              ),
              previewPath: FileOperationPreviewPath([
                FileProviderItemName.validated(folder),
                FileProviderItemName.validated('photo.arw'),
              ]),
            );
            return [
              FileOperation.create(
                source: source,
                destination: destination,
                intent: FileOperationIntent.copy,
              ),
            ];
          },
        );
      }

      final rawPlan = await planWithFolder('RAW');
      final jpgPlan = await planWithFolder('JPG');

      expect(rawPlan.operations.single.id, jpgPlan.operations.single.id);
      expect(rawPlan.digest, isNot(jpgPlan.digest));
      expect(rawPlan.digest, isNot(contains(path('source/photo.arw'))));
      expect(
        () => rawPlan.operations.single.preview.destination.components.add(
          'forged',
        ),
        throwsUnsupportedError,
      );
    },
  );

  test('inaccurate preview metadata is rejected before approval', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'source');

    await expectLater(
      planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final source = await platform.resolveFile(
            access,
            selection(path('source/photo.arw')),
          );
          final destination = FileProviderItemReference(
            providerIdentity: const FileProviderIdentity('controlled-provider'),
            itemIdentity: const FileProviderItemIdentity('jpg-photo'),
            opaqueItem: path('destination/JPG/photo.arw'),
            itemName: FileProviderItemName.validated('photo.arw'),
            previewPath: FileOperationPreviewPath([
              FileProviderItemName.validated('RAW'),
              FileProviderItemName.validated('photo.arw'),
            ]),
          );
          return [
            FileOperation.create(
              source: source,
              destination: destination,
              intent: FileOperationIntent.copy,
            ),
          ];
        },
      ),
      throwsArgumentError,
    );

    expect(platform.planningEndCount, 1);
    expect(platform.beginCount, 0);
  });

  test('leaf-only clone of an issued nested reference is rejected', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'source');

    await expectLater(
      planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final source = await platform.resolveFile(
            access,
            selection(path('source/photo.arw')),
          );
          final destinationRoot = await platform.resolveDirectory(
            access,
            selection(path('destination')),
          );
          final jpgDirectory = await platform.resolveChild(
            access: access,
            directory: destinationRoot,
            relativeName: FileProviderItemName.validated('JPG'),
          );
          final issuedDestination = await platform.resolveChild(
            access: access,
            directory: jpgDirectory,
            relativeName: FileProviderItemName.validated('photo.arw'),
          );
          final strippedClone = FileProviderItemReference(
            providerIdentity: issuedDestination.providerIdentity,
            itemIdentity: issuedDestination.itemIdentity,
            opaqueItem: issuedDestination.opaqueItem,
            itemName: issuedDestination.itemName,
            previewPath: FileOperationPreviewPath.single(
              FileProviderItemName.validated('photo.arw'),
            ),
          );
          return [
            FileOperation.create(
              source: source,
              destination: strippedClone,
              intent: FileOperationIntent.copy,
            ),
          ];
        },
      ),
      throwsArgumentError,
    );
  });

  test('reference from an earlier planning scope cannot be reused', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'source');
    late FileOperation captured;
    await planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        captured = FileOperation.create(
          source: await platform.resolveFile(
            access,
            selection(path('source/photo.arw')),
          ),
          destination: await platform.resolveFile(
            access,
            selection(path('destination/photo.arw')),
          ),
          intent: FileOperationIntent.copy,
        );
        return [captured];
      },
    );

    await expectLater(
      planFileOperations(
        platform: platform,
        buildOperations: (_) async => [captured],
      ),
      throwsArgumentError,
    );
  });

  test(
    'child resolution rejects a parent not issued in the active scope',
    () async {
      final platform = _ControlledPlatform();
      late FileProviderItemReference priorDirectory;
      await planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          priorDirectory = await platform.resolveDirectory(
            access,
            selection(path('destination')),
          );
          return [];
        },
      );

      await expectLater(
        planFileOperations(
          platform: platform,
          buildOperations: (access) async {
            await platform.resolveChild(
              access: access,
              directory: priorDirectory,
              relativeName: FileProviderItemName.validated('photo.arw'),
            );
            return [];
          },
        ),
        throwsArgumentError,
      );

      final fabricatedDirectory = FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('controlled-provider'),
        itemIdentity: const FileProviderItemIdentity('fabricated-directory'),
        opaqueItem: path('outside'),
        itemName: FileProviderItemName.validated('outside'),
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated('outside'),
        ),
      );
      await expectLater(
        planFileOperations(
          platform: platform,
          buildOperations: (access) async {
            await platform.resolveChild(
              access: access,
              directory: fabricatedDirectory,
              relativeName: FileProviderItemName.validated('photo.arw'),
            );
            return [];
          },
        ),
        throwsArgumentError,
      );
    },
  );

  test('planning access encloses listing and closes before preview', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('input/photo.arw'), 'raw');

    final plan = await planSortPhotos(
      input: selection(path('input')),
      output: selection(path('output')),
      platform: platform,
    );

    expect(plan.operations, hasLength(1));
    expect(platform.planningBeginCount, 1);
    expect(platform.planningEndCount, 1);
    expect(
      platform.events,
      containsAllInOrder([
        'planningBegin',
        'resolveDirectory',
        'resolveDirectory',
        'list',
        'inspectPlanning',
        'planningEnd',
      ]),
    );
    expect(platform.planningAccessActive, isFalse);
  });

  test('planning access closes when provider enumeration fails', () async {
    final platform = _ControlledPlatform(listingFails: true)
      ..addFile(path('input/photo.arw'), 'raw');

    await expectLater(
      planSortPhotos(
        input: selection(path('input')),
        output: selection(path('output')),
        platform: platform,
      ),
      throwsStateError,
    );

    expect(platform.planningBeginCount, 1);
    expect(platform.planningEndCount, 1);
    expect(platform.planningAccessActive, isFalse);
  });

  test(
    'partial planning access acquisition rolls back before throwing',
    () async {
      final platform = _ControlledPlatform(partialPlanningAccessFailure: true)
        ..addFile(path('input/photo.arw'), 'raw');

      await expectLater(
        planSortPhotos(
          input: selection(path('input')),
          output: selection(path('output')),
          platform: platform,
        ),
        throwsA(isA<FileOperationException>()),
      );

      expect(platform.activePlanningProviderLeaseCount, 0);
      expect(platform.planningBeginCount, 1);
      expect(platform.planningEndCount, 0);
      expect(platform.events, isNot(contains('resolveDirectory')));
    },
  );

  test(
    'Dart planning APIs reject ended or foreign access before provider I/O',
    () async {
      const platform = DartFileOperationPlatform();
      final emptyDirectory = Directory(path('empty'));
      await emptyDirectory.create();
      final access = await platform.beginPlanningAccess();
      final issuedDirectory = await platform.resolveDirectory(
        access,
        DartFileProviderSelection.fromPath(emptyDirectory.path),
      );
      await platform.endPlanningAccess(access);

      await expectLater(
        platform.resolveDirectory(
          access,
          DartFileProviderSelection.fromPath(emptyDirectory.path),
        ),
        throwsStateError,
      );
      await expectLater(
        platform.resolveFile(
          access,
          DartFileProviderSelection.fromPath(path('photo.arw')),
        ),
        throwsStateError,
      );
      await expectLater(
        platform.listDirectory(access, issuedDirectory),
        throwsStateError,
      );
      await expectLater(
        platform.resolveChild(
          access: access,
          directory: issuedDirectory,
          relativeName: FileProviderItemName.validated('photo.arw'),
        ),
        throwsStateError,
      );
      await expectLater(
        platform.locationsEquivalent(access, issuedDirectory, issuedDirectory),
        throwsStateError,
      );
      expect(
        () => platform.inspectDestination(access, issuedDirectory),
        throwsStateError,
      );

      final foreignAccess = FileOperationPlanningAccess(opaqueAccess: Object());
      await expectLater(
        platform.resolveDirectory(
          foreignAccess,
          DartFileProviderSelection.fromPath(emptyDirectory.path),
        ),
        throwsStateError,
      );
    },
  );

  test(
    'sort planning resolves and lists entirely through the platform',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('input/photo.arw'), 'raw')
        ..addFile(path('input/notes.txt'), 'notes');
      final output = Directory(path('output'));

      final plan = await planSortPhotos(
        input: selection(path('input')),
        output: selection(output.path),
        platform: platform,
      );

      expect(platform.resolveDirectoryCalls, [path('input'), path('output')]);
      expect(platform.listDirectoryCalls, [path('input')]);
      expect(plan.operations, hasLength(1));
      expect(
        plan.operations.single.destination.opaqueItem,
        path('output/RAW/photo.arw'),
      );
      expect(output.existsSync(), isFalse);
    },
  );

  test(
    'kept export resolves sources and destination through platform in order',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/second.arw'), 'second')
        ..addFile(path('source/first.arw'), 'first');
      final plan = await planKeptPhotoExport(
        destination: selection(path('destination')),
        pairs: [
          KeptPhotoExportSelection(
            stem: 'second',
            raw: selection(path('source/second.arw')),
          ),
          KeptPhotoExportSelection(
            stem: 'first',
            raw: selection(path('source/first.arw')),
          ),
        ],
        session: CullSession({'first': CullFlag.keep, 'second': CullFlag.keep}),
        includeJpgs: false,
        platform: platform,
      );

      expect(
        plan.operations.map((operation) => operation.destination.opaqueItem),
        [path('destination/first.arw'), path('destination/second.arw')],
      );
      expect(platform.resolveDirectoryCalls, [path('destination')]);
      expect(
        platform.resolveFileCalls,
        containsAll([path('source/first.arw'), path('source/second.arw')]),
      );
    },
  );

  test('kept export planning preserves an existing photo', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'source')
      ..addFile(path('destination/photo.arw'), 'existing');
    final plan = await planKeptPhotoExport(
      destination: selection(path('destination')),
      pairs: [
        KeptPhotoExportSelection(
          stem: 'photo',
          raw: selection(path('source/photo.arw')),
        ),
      ],
      session: CullSession({'photo': CullFlag.keep}),
      includeJpgs: false,
      platform: platform,
    );

    final execution = await execute(plan, platform);

    expect(
      execution.results.single.status,
      FileOperationStatus.skippedConflict,
    );
    expect(platform.contents(path('destination/photo.arw')), 'existing');
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.beginCount, 0);
  });

  test(
    'operation-scoped access begins and ends exactly once around success',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      expect(execution.results.single.status, FileOperationStatus.copied);
      expect(platform.beginCount, 1);
      expect(platform.endCount, 1);
      expect(
        platform.events,
        containsAllInOrder([
          'begin',
          'capability',
          'pin',
          'prepare',
          'copy',
          'end',
        ]),
      );
    },
  );

  test(
    'capability rejection happens before every filesystem mutation',
    () async {
      final platform = _ControlledPlatform(
        capabilityFailure: FileOperationStatus.accessDenied,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      expect(execution.results.single.status, FileOperationStatus.accessDenied);
      expect(platform.events, isNot(contains('prepare')));
      expect(platform.events, isNot(contains('copy')));
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
      expect(platform.endCount, 1);
    },
  );

  test(
    'destination parent preparation effects survive a later failure',
    () async {
      final platform = _ControlledPlatform(prepareCreatesThenThrows: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destinationParent,
        FileOperationDestinationParentState.created,
      );
      expect(
        result.recovery.map((item) => item.action),
        contains(FileOperationRecoveryAction.reviewDestinationParent),
      );
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
    },
  );

  test(
    'successful approved parent creation needs no recovery action',
    () async {
      final platform = _ControlledPlatform(prepareCreates: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final result = (await execute(planned.plan, platform)).results.single;

      expect(result.status, FileOperationStatus.copied);
      expect(
        result.effects.destinationParent,
        FileOperationDestinationParentState.created,
      );
      expect(
        result.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.reviewDestinationParent)),
      );
      expect(result.recoveryGuidance, 'No action needed.');
    },
  );

  test(
    'committed copy does not review its approved parent after release error',
    () async {
      final platform = _ControlledPlatform(
        prepareCreates: true,
        accessReleaseFails: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final result = (await execute(planned.plan, platform)).results.single;

      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(
        result.effects.destinationParent,
        FileOperationDestinationParentState.created,
      );
      expect(
        result.recovery.map((item) => item.action),
        contains(FileOperationRecoveryAction.reviewProviderAccess),
      );
      expect(
        result.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.reviewDestinationParent)),
      );
    },
  );

  test('provider unavailable is explicit and does not mutate', () async {
    final platform = _ControlledPlatform(providerUnavailable: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );

    final execution = await execute(planned.plan, platform);

    expect(
      execution.results.single.status,
      FileOperationStatus.unavailableProviderItem,
    );
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.contains(path('destination/photo.arw')), isFalse);
    expect(platform.endCount, 0);
  });

  test(
    'partial operation access acquisition rolls back before throwing',
    () async {
      final platform = _ControlledPlatform(partialAccessFailure: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      expect(
        execution.results.single.status,
        FileOperationStatus.unavailableProviderItem,
      );
      expect(platform.activeProviderLeaseCount, 0);
      expect(platform.endCount, 0);
      expect(platform.events, isNot(contains('capability')));
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
    },
  );

  test(
    'mismatched operation access is rejected and released before mutation',
    () async {
      final platform = _ControlledPlatform(wrongAccessIdentity: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      expect(execution.results.single.status, FileOperationStatus.failed);
      expect(platform.events, isNot(contains('capability')));
      expect(platform.events, containsAllInOrder(['begin', 'end']));
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
    },
  );

  test(
    'source disappearance after planning is explicit and non-destructive',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );
      platform.removeFile(path('source/photo.arw'));

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.sourceMissing);
      expect(result.effects.source, FileOperationSourceState.missing);
      expect(
        result.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(platform.contains(path('destination/photo.arw')), isFalse);
      expect(platform.endCount, 1);
    },
  );

  test('source replacement after planning is rejected before copy', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/photo.arw'), 'original');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );
    platform.addFile(path('source/photo.arw'), 'replacement');

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.source, FileOperationSourceState.changed);
    expect(platform.events, isNot(contains('copy')));
    expect(platform.contents(path('source/photo.arw')), 'replacement');
    expect(platform.contains(path('destination/photo.arw')), isFalse);
  });

  test(
    'portable Dart copy and move fail closed without touching real files',
    () async {
      final source = await writeFile('source/photo.arw', 'source');
      final dartPlatform = const DartFileOperationPlatform();
      for (final intent in FileOperationIntent.values) {
        final destination = File(path('destination/${intent.name}.arw'));
        final plan = await planFileOperations(
          platform: dartPlatform,
          buildOperations: (access) async {
            final sourceReference = await dartPlatform.resolveFile(
              access,
              DartFileProviderSelection.fromPath(source.path),
            );
            final destinationReference = await dartPlatform.resolveFile(
              access,
              DartFileProviderSelection.fromPath(destination.path),
            );
            return [
              FileOperation.create(
                source: sourceReference,
                destination: destinationReference,
                intent: intent,
              ),
            ];
          },
        );

        final execution = await execute(plan, dartPlatform);

        expect(execution.results.single.status, FileOperationStatus.failed);
        expect(await source.readAsString(), 'source');
        expect(await destination.exists(), isFalse);
      }
    },
  );

  test(
    'copy destination racer is preserved by atomic no-replace capability',
    () async {
      final platform = _ControlledPlatform(destinationAppearsDuringCopy: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      expect(
        execution.results.single.status,
        FileOperationStatus.skippedConflict,
      );
      expect(
        execution.results.single.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(platform.contents(path('destination/photo.arw')), 'racer');
      expect(platform.contents(path('source/photo.arw')), 'source');
    },
  );

  test(
    'promotion destination racer is preserved and owned temp is cleaned',
    () async {
      final platform = _ControlledPlatform(
        destinationAppearsDuringPromotion: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.skippedConflict);
      expect(
        result.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(result.effects.temporary, FileOperationTemporaryState.cleaned);
      expect(platform.contents(path('destination/photo.arw')), 'racer');
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.temporaryCount, 0);
    },
  );

  test('interrupted temporary copy cleans only its owned artifact', () async {
    final platform = _ControlledPlatform(interruptTemporaryCopy: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.source, FileOperationSourceState.retained);
    expect(result.effects.temporary, FileOperationTemporaryState.cleaned);
    expect(platform.temporaryCount, 0);
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.contains(path('destination/photo.arw')), isFalse);
    expect(
      platform.events,
      containsAllInOrder(['copyTemporary', 'cleanup', 'end']),
    );
  });

  test(
    'temporary create close failure still cleans its reported artifact',
    () async {
      final platform = _ControlledPlatform(tempCreateCloseFails: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(result.effects.temporary, FileOperationTemporaryState.cleaned);
      expect(platform.temporaryCount, 0);
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
      expect(platform.events, containsAllInOrder(['cleanup', 'end']));
    },
  );

  test('partial-write ENOSPC is cleaned and source is preserved', () async {
    final platform = _ControlledPlatform(partialWriteEnospc: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );

    final execution = await execute(planned.plan, platform);

    expect(
      execution.results.single.status,
      FileOperationStatus.insufficientStorage,
    );
    expect(platform.partialDestinationCleaned, isTrue);
    expect(platform.contains(path('destination/photo.arw')), isFalse);
    expect(platform.contents(path('source/photo.arw')), 'source');
  });

  test('recovery conflict cannot erase primary ENOSPC status', () async {
    final platform = _ControlledPlatform(
      partialWriteEnospc: true,
      recoveryDestinationAppears: true,
    )..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.insufficientStorage);
    expect(
      result.issues,
      contains(
        isA<FileOperationIssue>()
            .having(
              (issue) => issue.stage,
              'stage',
              FileOperationStage.inspectRecovery,
            )
            .having(
              (issue) => issue.status,
              'status',
              FileOperationStatus.skippedConflict,
            ),
      ),
    );
    expect(
      result.recovery.map((item) => item.action),
      containsAll([
        FileOperationRecoveryAction.freeStorage,
        FileOperationRecoveryAction.chooseDifferentDestination,
      ]),
    );
    expect(platform.contents(path('destination/photo.arw')), 'racer');
    expect(platform.contents(path('source/photo.arw')), 'source');
  });

  test(
    'concurrent executions cannot both commit the same destination',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final executions = await Future.wait([
        execute(planned.plan, platform),
        execute(planned.plan, platform),
      ]);

      expect(executions.map((value) => value.results.single.status).toSet(), {
        FileOperationStatus.copied,
        FileOperationStatus.skippedConflict,
      });
      final conflict = executions
          .map((execution) => execution.results.single)
          .singleWhere(
            (result) => result.status == FileOperationStatus.skippedConflict,
          );
      expect(
        conflict.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(platform.contents(path('destination/photo.arw')), 'source');
    },
  );

  test(
    'same-size source mutation after copy is rejected before promotion',
    () async {
      final platform = _ControlledPlatform(mutateSourceAfterTemporaryCopy: true)
        ..addFile(path('source/photo.arw'), 'AAAA');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      expect(execution.results.single.status, FileOperationStatus.failed);
      expect(platform.contents(path('source/photo.arw')), 'BBBB');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
      expect(platform.deleteSourceCalls, 0);
    },
  );

  test('source replacement after promotion is not deleted', () async {
    final platform = _ControlledPlatform(replaceSourceAfterPromotion: true)
      ..addFile(path('source/photo.arw'), 'original');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.destination, FileOperationDestinationState.committed);
    expect(result.effects.source, FileOperationSourceState.changed);
    expect(platform.contents(path('source/photo.arw')), 'replacement');
    expect(platform.contents(path('destination/photo.arw')), 'original');
    expect(result.recoveryGuidance, contains('source remains'));
  });

  test('in-place source mutation after promotion is not deleted', () async {
    final platform = _ControlledPlatform(mutateSourceAfterPromotion: true)
      ..addFile(path('source/photo.arw'), 'original');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.source, FileOperationSourceState.changed);
    expect(result.effects.destination, FileOperationDestinationState.committed);
    expect(platform.contents(path('source/photo.arw')), 'mutation');
    expect(platform.contents(path('destination/photo.arw')), 'original');
  });

  test(
    'missing source after promotion has distinct recovery guidance',
    () async {
      final platform = _ControlledPlatform(removeSourceAfterPromotion: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.effects.source, FileOperationSourceState.missing);
      expect(
        result.recovery.map((item) => item.action),
        contains(FileOperationRecoveryAction.reviewMissingSource),
      );
      expect(
        result.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.preserveBothCopies)),
      );
    },
  );

  test(
    'thrown source-delete error cannot downgrade committed destination',
    () async {
      final platform = _ControlledPlatform(sourceDeleteThrows: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.accessDenied);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(result.effects.source, FileOperationSourceState.unknown);
      expect(platform.contents(path('destination/photo.arw')), 'source');
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(
        result.issues.map((issue) => issue.stage),
        isNot(contains(FileOperationStage.inspectRecovery)),
      );
      expect(
        result.recovery.map((item) => item.action),
        contains(FileOperationRecoveryAction.verifySource),
      );
      expect(
        result.recovery.map((item) => item.action),
        isNot(contains(FileOperationRecoveryAction.preserveBothCopies)),
      );
    },
  );

  test(
    'verified promotion deletes only the atomically matched pinned source',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.moved);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(result.effects.source, FileOperationSourceState.deleted);
      expect(platform.contains(path('source/photo.arw')), isFalse);
      expect(platform.contents(path('destination/photo.arw')), 'source');
    },
  );

  test(
    'promotion committed then thrown reports destination and retained source',
    () async {
      final platform = _ControlledPlatform(promotionCommitsThenThrows: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(platform.contents(path('destination/photo.arw')), 'source');
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(result.recoveryGuidance, contains('source remains'));
    },
  );

  test(
    'unknown promotion outcome remains unknown and requires verification',
    () async {
      final platform = _ControlledPlatform(promotionOutcomeUnknown: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(result.effects.destination, FileOperationDestinationState.unknown);
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(
        result.recovery.map((item) => item.action),
        contains(FileOperationRecoveryAction.verifyDestination),
      );
      expect(platform.temporaryCount, 0);
    },
  );

  test('untyped after-commit promotion error stays unknown and cleanup cannot '
      'delete destination', () async {
    final platform = _ControlledPlatform(
      untypedPromotionCommitsThenThrows: true,
    )..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.destination, FileOperationDestinationState.unknown);
    expect(platform.contents(path('destination/photo.arw')), 'source');
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.events, containsAllInOrder(['promote', 'cleanup', 'end']));
    expect(platform.temporaryAlreadyAbsentCount, 1);
    expect(platform.temporaryCount, 0);
  });

  test('malformed typed promotion outcome fails closed as unknown', () async {
    final platform = _ControlledPlatform(malformedPromotionOutcome: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.destination, FileOperationDestinationState.unknown);
    expect(result.effects.source, FileOperationSourceState.retained);
    expect(platform.contents(path('destination/photo.arw')), 'source');
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.temporaryAlreadyAbsentCount, 1);
  });

  test(
    'temporary cleanup failure changes result and access still releases',
    () async {
      final platform = _ControlledPlatform(
        mutateSourceAfterTemporaryCopy: true,
        tempCleanupFails: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(result.effects.temporary, FileOperationTemporaryState.mayRemain);
      expect(result.effects.temporaryArtifact, isNotNull);
      expect(result.recoveryGuidance, contains('temporary'));
      expect(platform.events, containsAllInOrder(['cleanup', 'end']));
      expect(platform.endCount, 1);
    },
  );

  test(
    'cleanup failure preserves primary insufficient-storage recovery',
    () async {
      final platform = _ControlledPlatform(
        temporaryCopyEnospc: true,
        tempCleanupFails: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(result.effects.temporary, FileOperationTemporaryState.mayRemain);
      expect(
        result.recovery.map((item) => item.action),
        containsAll([
          FileOperationRecoveryAction.freeStorage,
          FileOperationRecoveryAction.cleanTemporaryArtifact,
        ]),
      );
      expect(platform.contents(path('source/photo.arw')), 'source');
    },
  );

  test(
    'generic verify failure and cleanup failure preserve both recoveries',
    () async {
      final platform = _ControlledPlatform(
        mutateSourceAfterTemporaryCopy: true,
        tempCleanupFails: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final result = (await execute(planned.plan, platform)).results.single;

      expect(result.status, FileOperationStatus.failed);
      expect(
        result.recovery.map((item) => item.action),
        containsAll([
          FileOperationRecoveryAction.reviewProviderError,
          FileOperationRecoveryAction.cleanTemporaryArtifact,
        ]),
      );
      expect(
        result.issues.map((issue) => issue.stage),
        containsAll([
          FileOperationStage.verifyTemporary,
          FileOperationStage.cleanupTemporary,
        ]),
      );
    },
  );

  test('changed temp identity is retained as a cleanup continuation', () async {
    final platform = _ControlledPlatform(
      interruptTemporaryCopy: true,
      tempIdentityChangesBeforeCleanup: true,
    )..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );

    final execution = await execute(planned.plan, platform);

    final result = execution.results.single;
    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.temporary, FileOperationTemporaryState.mayRemain);
    expect(result.effects.temporaryArtifact, isNotNull);
    expect(platform.temporaryCount, 1);
    expect(platform.contents(path('source/photo.arw')), 'source');
    expect(platform.contains(path('destination/photo.arw')), isFalse);
    expect(platform.endCount, 1);
  });

  test('scoped recovery conditionally cleans retained temp only', () async {
    final platform = _ControlledPlatform(
      interruptTemporaryCopy: true,
      tempCleanupFailures: 1,
    )..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
      intent: FileOperationIntent.move,
    );
    final execution = await execute(planned.plan, platform);
    final continuation = execution.results.single;
    expect(
      continuation.effects.temporary,
      FileOperationTemporaryState.mayRemain,
    );

    final recovered = await recoverTemporaryArtifact(
      continuation,
      platform: platform,
    );

    expect(recovered.status, continuation.status);
    expect(recovered.effects.destination, continuation.effects.destination);
    expect(recovered.effects.source, continuation.effects.source);
    expect(
      recovered.effects.destinationParent,
      continuation.effects.destinationParent,
    );
    expect(recovered.effects.temporary, FileOperationTemporaryState.cleaned);
    expect(recovered.effects.temporaryArtifact, isNull);
    expect(platform.temporaryCount, 0);
    expect(platform.activeProviderLeaseCount, 0);
    expect(platform.beginCount, 2);
    expect(platform.endCount, 2);
    expect(
      platform.events.where((event) => event == 'capability'),
      hasLength(1),
    );
    expect(
      platform.events.where((event) => event == 'cleanupCapability'),
      hasLength(1),
    );
  });

  test(
    'access release failure after commit is explicit and truthful',
    () async {
      final platform = _ControlledPlatform(accessReleaseFails: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(
        result.issues.map((issue) => issue.stage),
        contains(FileOperationStage.releaseAccess),
      );
      expect(result.recoveryGuidance, contains('access release'));
    },
  );

  test('operation access release attempts every provider scope', () async {
    final platform = _ControlledPlatform(twoScopeReleaseFirstFails: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );

    final result = (await execute(planned.plan, platform)).results.single;

    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.destination, FileOperationDestinationState.committed);
    expect(
      platform.events,
      containsAllInOrder(['releaseSource', 'releaseDestination']),
    );
    expect(platform.activeProviderLeaseCount, 0);
    expect(
      result.issues.map((issue) => issue.stage),
      contains(FileOperationStage.releaseAccess),
    );
  });

  test(
    'release failure preserves primary insufficient-storage recovery',
    () async {
      final platform = _ControlledPlatform(
        partialWriteEnospc: true,
        accessReleaseFails: true,
      )..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(
        result.recovery.map((item) => item.action),
        containsAll([
          FileOperationRecoveryAction.freeStorage,
          FileOperationRecoveryAction.reviewProviderAccess,
        ]),
      );
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
    },
  );

  test('release failure preserves primary missing-source recovery', () async {
    final platform = _ControlledPlatform(accessReleaseFails: true)
      ..addFile(path('source/photo.arw'), 'source');
    final planned = await planOne(
      platform,
      sourcePath: path('source/photo.arw'),
      destinationPath: path('destination/photo.arw'),
    );
    platform.removeFile(path('source/photo.arw'));

    final result = (await execute(planned.plan, platform)).results.single;

    expect(result.status, FileOperationStatus.failed);
    expect(result.effects.source, FileOperationSourceState.missing);
    expect(
      result.recovery.map((item) => item.action),
      containsAll([
        FileOperationRecoveryAction.reselectSource,
        FileOperationRecoveryAction.reviewProviderAccess,
      ]),
    );
  });

  test(
    'copy handle close failure after commit is not reported as success',
    () async {
      final platform = _ControlledPlatform(copyCloseFailsAfterCommit: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
      );

      final execution = await execute(planned.plan, platform);

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(platform.contents(path('destination/photo.arw')), 'source');
      expect(platform.endCount, 1);
    },
  );

  test(
    'recovery inspection failure cannot abort later operation results',
    () async {
      final platform =
          _ControlledPlatform(
              failFirstCopy: true,
              recoveryInspectionFails: true,
            )
            ..addFile(path('source/first.arw'), 'first')
            ..addFile(path('source/second.arw'), 'second');
      final plan = await planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final firstSource = await platform.resolveFile(
            access,
            selection(path('source/first.arw')),
          );
          final secondSource = await platform.resolveFile(
            access,
            selection(path('source/second.arw')),
          );
          final firstDestination = await platform.resolveFile(
            access,
            selection(path('destination/first.arw')),
          );
          final secondDestination = await platform.resolveFile(
            access,
            selection(path('destination/second.arw')),
          );
          return [
            FileOperation.create(
              source: firstSource,
              destination: firstDestination,
              intent: FileOperationIntent.copy,
            ),
            FileOperation.create(
              source: secondSource,
              destination: secondDestination,
              intent: FileOperationIntent.copy,
            ),
          ];
        },
      );
      platform.executionHasStarted = true;

      final execution = await execute(plan, platform);

      expect(execution.results.map((result) => result.status), [
        FileOperationStatus.failed,
        FileOperationStatus.copied,
      ]);
      expect(
        execution.results.first.issues.map((issue) => issue.stage),
        contains(FileOperationStage.inspectRecovery),
      );
      expect(platform.contents(path('destination/second.arw')), 'second');
    },
  );

  test(
    'cancellation after one success reports remaining operations cancelled',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/first.arw'), 'first')
        ..addFile(path('source/second.arw'), 'second');
      final plan = await planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final first = await platform.resolveFile(
            access,
            selection(path('source/first.arw')),
          );
          final second = await platform.resolveFile(
            access,
            selection(path('source/second.arw')),
          );
          final firstDestination = await platform.resolveFile(
            access,
            selection(path('destination/first.arw')),
          );
          final secondDestination = await platform.resolveFile(
            access,
            selection(path('destination/second.arw')),
          );
          return [
            FileOperation.create(
              source: first,
              destination: firstDestination,
              intent: FileOperationIntent.copy,
            ),
            FileOperation.create(
              source: second,
              destination: secondDestination,
              intent: FileOperationIntent.copy,
            ),
          ];
        },
      );
      final execution = await execute(
        plan,
        platform,
        shouldCancel: () => platform.contains(path('destination/first.arw')),
      );

      expect(execution.results.map((result) => result.status), [
        FileOperationStatus.copied,
        FileOperationStatus.cancelled,
      ]);
      expect(platform.beginCount, 1);
      expect(platform.endCount, 1);
    },
  );

  test(
    'progress observer reports each appended preflight and cancelled result once',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/blocked.arw'), 'blocked')
        ..addFile(path('source/second.arw'), 'second')
        ..addFile(path('source/third.arw'), 'third')
        ..addFile(path('destination/blocked.arw'), 'existing');
      final plan = await planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final operations = <FileOperation>[];
          for (final name in ['blocked.arw', 'second.arw', 'third.arw']) {
            operations.add(
              FileOperation.create(
                source: await platform.resolveFile(
                  access,
                  selection(path('source/$name')),
                ),
                destination: await platform.resolveFile(
                  access,
                  selection(path('destination/$name')),
                ),
                intent: FileOperationIntent.copy,
              ),
            );
          }
          return operations;
        },
      );
      var cancelled = false;
      final observations =
          <({FileOperationStatus status, int completed, int total})>[];

      final execution = await executeFileOperationPlan(
        plan,
        approval: FileOperationApproval.forPlan(plan),
        platform: platform,
        shouldCancel: () => cancelled,
        onResult: (result, completed, total) {
          observations.add((
            status: result.status,
            completed: completed,
            total: total,
          ));
          if (completed == 1) cancelled = true;
        },
      );

      expect(execution.results.map((result) => result.status), [
        FileOperationStatus.skippedConflict,
        FileOperationStatus.cancelled,
        FileOperationStatus.cancelled,
      ]);
      expect(observations, [
        (status: FileOperationStatus.skippedConflict, completed: 1, total: 3),
        (status: FileOperationStatus.cancelled, completed: 2, total: 3),
        (status: FileOperationStatus.cancelled, completed: 3, total: 3),
      ]);
      expect(platform.beginCount, 0);
    },
  );

  test('progress observer failure cannot interrupt execution', () async {
    final platform = _ControlledPlatform()
      ..addFile(path('source/first.arw'), 'first')
      ..addFile(path('source/second.arw'), 'second');
    final plan = await planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        final operations = <FileOperation>[];
        for (final name in ['first.arw', 'second.arw']) {
          operations.add(
            FileOperation.create(
              source: await platform.resolveFile(
                access,
                selection(path('source/$name')),
              ),
              destination: await platform.resolveFile(
                access,
                selection(path('destination/$name')),
              ),
              intent: FileOperationIntent.copy,
            ),
          );
        }
        return operations;
      },
    );
    var observationCount = 0;

    final execution = await executeFileOperationPlan(
      plan,
      approval: FileOperationApproval.forPlan(plan),
      platform: platform,
      onResult: (_, _, _) {
        observationCount++;
        throw StateError('observer failure must be isolated');
      },
    );

    expect(execution.results.map((result) => result.status), [
      FileOperationStatus.copied,
      FileOperationStatus.copied,
    ]);
    expect(observationCount, 2);
    expect(platform.contents(path('destination/first.arw')), 'first');
    expect(platform.contents(path('destination/second.arw')), 'second');
  });

  test(
    'one-shot inner cancellation latches the batch from a cancellation issue',
    () async {
      final platform = _ControlledPlatform(tempCleanupFails: true)
        ..addFile(path('source/first.arw'), 'first')
        ..addFile(path('source/second.arw'), 'second');
      final plan = await planFileOperations(
        platform: platform,
        buildOperations: (access) async {
          final operations = <FileOperation>[];
          for (final name in ['first.arw', 'second.arw']) {
            operations.add(
              FileOperation.create(
                source: await platform.resolveFile(
                  access,
                  selection(path('source/$name')),
                ),
                destination: await platform.resolveFile(
                  access,
                  selection(path('destination/$name')),
                ),
                intent: FileOperationIntent.move,
              ),
            );
          }
          return operations;
        },
      );
      var cancellationDelivered = false;

      final execution = await execute(
        plan,
        platform,
        shouldCancel: () {
          if (!cancellationDelivered &&
              platform.events.contains('copyTemporary')) {
            cancellationDelivered = true;
            return true;
          }
          return false;
        },
      );

      expect(execution.results.map((result) => result.status), [
        FileOperationStatus.failed,
        FileOperationStatus.cancelled,
      ]);
      expect(
        execution.results.first.issues.map((issue) => issue.status),
        contains(FileOperationStatus.cancelled),
      );
      expect(execution.results.last.issues, isEmpty);
      expect(platform.beginCount, 1);
      expect(platform.endCount, 1);
      expect(platform.contains(path('destination/first.arw')), isFalse);
      expect(platform.contains(path('destination/second.arw')), isFalse);
      expect(platform.contents(path('source/first.arw')), 'first');
      expect(platform.contents(path('source/second.arw')), 'second');
    },
  );

  test('provider cancellation latches the batch without a callback', () async {
    final platform =
        _ControlledPlatform(capabilityFailure: FileOperationStatus.cancelled)
          ..addFile(path('source/first.arw'), 'first')
          ..addFile(path('source/second.arw'), 'second');
    final plan = await planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        final operations = <FileOperation>[];
        for (final name in ['first.arw', 'second.arw']) {
          operations.add(
            FileOperation.create(
              source: await platform.resolveFile(
                access,
                selection(path('source/$name')),
              ),
              destination: await platform.resolveFile(
                access,
                selection(path('destination/$name')),
              ),
              intent: FileOperationIntent.copy,
            ),
          );
        }
        return operations;
      },
    );

    final execution = await execute(plan, platform);

    expect(execution.results.map((result) => result.status), [
      FileOperationStatus.cancelled,
      FileOperationStatus.cancelled,
    ]);
    expect(
      execution.results.first.issues.map((issue) => issue.status),
      contains(FileOperationStatus.cancelled),
    );
    expect(execution.results.last.issues, isEmpty);
    expect(platform.beginCount, 1);
    expect(platform.endCount, 1);
    expect(
      platform.events.where((event) => event == 'capability'),
      hasLength(1),
    );
    expect(platform.contains(path('destination/first.arw')), isFalse);
    expect(platform.contains(path('destination/second.arw')), isFalse);
  });

  test(
    'cancellation during temporary copy prevents promotion and source delete',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(
        planned.plan,
        platform,
        shouldCancel: () => platform.events.contains('copyTemporary'),
      );

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.cancelled);
      expect(
        result.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(result.effects.temporary, FileOperationTemporaryState.cleaned);
      expect(platform.events, isNot(contains('promote')));
      expect(platform.events, isNot(contains('deleteSource')));
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contains(path('destination/photo.arw')), isFalse);
      expect(platform.temporaryCount, 0);
      expect(platform.endCount, 1);
    },
  );

  test(
    'cancellation after promotion retains source and committed destination',
    () async {
      final platform = _ControlledPlatform()
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final execution = await execute(
        planned.plan,
        platform,
        shouldCancel: () => platform.events.contains('promote'),
      );

      final result = execution.results.single;
      expect(result.status, FileOperationStatus.cancelled);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(result.effects.temporary, FileOperationTemporaryState.none);
      expect(platform.events, isNot(contains('deleteSource')));
      expect(platform.contents(path('source/photo.arw')), 'source');
      expect(platform.contents(path('destination/photo.arw')), 'source');
      expect(
        result.recovery.map((item) => item.action),
        containsAll([
          FileOperationRecoveryAction.preserveBothCopies,
          FileOperationRecoveryAction.reviewCompletedOperations,
        ]),
      );
      expect(platform.endCount, 1);
    },
  );

  test(
    'cancellation plus cleanup failure preserves both reasons and effects',
    () async {
      final platform = _ControlledPlatform(tempCleanupFails: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final result = (await execute(
        planned.plan,
        platform,
        shouldCancel: () => platform.events.contains('copyTemporary'),
      )).results.single;

      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.notCommitted,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(result.effects.temporary, FileOperationTemporaryState.mayRemain);
      expect(
        result.issues.map((issue) => issue.status),
        contains(FileOperationStatus.cancelled),
      );
      expect(
        result.recovery.map((item) => item.action),
        containsAll([
          FileOperationRecoveryAction.reviewCompletedOperations,
          FileOperationRecoveryAction.cleanTemporaryArtifact,
        ]),
      );
      expect(platform.events, containsAllInOrder(['cleanup', 'end']));
    },
  );

  test(
    'cancellation after commit plus release failure preserves both reasons',
    () async {
      final platform = _ControlledPlatform(accessReleaseFails: true)
        ..addFile(path('source/photo.arw'), 'source');
      final planned = await planOne(
        platform,
        sourcePath: path('source/photo.arw'),
        destinationPath: path('destination/photo.arw'),
        intent: FileOperationIntent.move,
      );

      final result = (await execute(
        planned.plan,
        platform,
        shouldCancel: () => platform.events.contains('promote'),
      )).results.single;

      expect(result.status, FileOperationStatus.failed);
      expect(
        result.effects.destination,
        FileOperationDestinationState.committed,
      );
      expect(result.effects.source, FileOperationSourceState.retained);
      expect(result.effects.temporary, FileOperationTemporaryState.none);
      expect(
        result.issues.map((issue) => issue.status),
        contains(FileOperationStatus.cancelled),
      );
      expect(
        result.recovery.map((item) => item.action),
        containsAll([
          FileOperationRecoveryAction.preserveBothCopies,
          FileOperationRecoveryAction.reviewCompletedOperations,
          FileOperationRecoveryAction.reviewProviderAccess,
        ]),
      );
      expect(platform.events, isNot(contains('deleteSource')));
    },
  );

  test(
    'legacy sorter and exporter fail closed before any filesystem mutation',
    () async {
      final input = Directory(path('legacy-input'));
      final output = Directory(path('legacy-output'));
      final source = await writeFile('legacy-input/photo.arw', 'source');
      final pair = PhotoPair(stem: 'photo', raw: source);

      await expectLater(
        sortPhotos(input: input, output: output),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('Task 3B'),
          ),
        ),
      );
      await expectLater(
        exportKept(
          source: input,
          destination: output,
          pairs: [pair],
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
      expect(await output.exists(), isFalse);
    },
  );
}

class _ControlledPlatform implements FileOperationPlatform {
  _ControlledPlatform({
    this.providerUnavailable = false,
    this.partialAccessFailure = false,
    this.partialPlanningAccessFailure = false,
    this.destinationAppearsDuringCopy = false,
    this.destinationAppearsDuringPromotion = false,
    this.partialWriteEnospc = false,
    this.tempCreateCloseFails = false,
    this.interruptTemporaryCopy = false,
    this.temporaryCopyEnospc = false,
    this.mutateSourceAfterTemporaryCopy = false,
    this.mutateSourceAfterPromotion = false,
    this.replaceSourceAfterPromotion = false,
    this.removeSourceAfterPromotion = false,
    this.promotionCommitsThenThrows = false,
    this.promotionOutcomeUnknown = false,
    this.untypedPromotionCommitsThenThrows = false,
    this.malformedPromotionOutcome = false,
    this.tempCleanupFails = false,
    this.tempCleanupFailures = 0,
    this.tempIdentityChangesBeforeCleanup = false,
    this.accessReleaseFails = false,
    this.copyCloseFailsAfterCommit = false,
    this.failFirstCopy = false,
    this.recoveryInspectionFails = false,
    this.recoveryDestinationAppears = false,
    this.listingFails = false,
    this.wrongAccessIdentity = false,
    this.sourceDeleteThrows = false,
    this.prepareCreatesThenThrows = false,
    this.prepareCreates = false,
    this.capabilityReportsCopied = false,
    this.promotionReportsMovedWithoutCommit = false,
    this.genericPromotionConflict = false,
    this.tempCopyThrowsMisplacedConsumedPromotion = false,
    this.prepareEnoent = false,
    this.prepareTypedSourceMissing = false,
    this.promotionEnoent = false,
    this.tempCleanupEnoent = false,
    this.capabilityClaimsEffects = false,
    this.twoScopeReleaseFirstFails = false,
    this.sourceDeleteConflict = false,
    this.capabilityFailure,
    this.planningInspectionFailure,
  });

  final bool providerUnavailable;
  final bool partialAccessFailure;
  final bool partialPlanningAccessFailure;
  final bool destinationAppearsDuringCopy;
  final bool destinationAppearsDuringPromotion;
  final bool partialWriteEnospc;
  final bool tempCreateCloseFails;
  final bool interruptTemporaryCopy;
  final bool temporaryCopyEnospc;
  final bool mutateSourceAfterTemporaryCopy;
  final bool mutateSourceAfterPromotion;
  final bool replaceSourceAfterPromotion;
  final bool removeSourceAfterPromotion;
  final bool promotionCommitsThenThrows;
  final bool promotionOutcomeUnknown;
  final bool untypedPromotionCommitsThenThrows;
  final bool malformedPromotionOutcome;
  final bool tempCleanupFails;
  final int tempCleanupFailures;
  final bool tempIdentityChangesBeforeCleanup;
  final bool accessReleaseFails;
  final bool copyCloseFailsAfterCommit;
  final bool failFirstCopy;
  final bool recoveryInspectionFails;
  final bool recoveryDestinationAppears;
  final bool listingFails;
  final bool wrongAccessIdentity;
  final bool sourceDeleteThrows;
  final bool prepareCreatesThenThrows;
  final bool prepareCreates;
  final bool capabilityReportsCopied;
  final bool promotionReportsMovedWithoutCommit;
  final bool genericPromotionConflict;
  final bool tempCopyThrowsMisplacedConsumedPromotion;
  final bool prepareEnoent;
  final bool prepareTypedSourceMissing;
  final bool promotionEnoent;
  final bool tempCleanupEnoent;
  final bool capabilityClaimsEffects;
  final bool twoScopeReleaseFirstFails;
  final bool sourceDeleteConflict;
  final FileOperationStatus? capabilityFailure;
  final FileOperationStatus? planningInspectionFailure;

  final Map<String, _FakeItem> _items = {};
  final Map<String, _FakeTemporary> _temporaryArtifacts = {};
  final List<String> events = [];
  final List<String> resolveDirectoryCalls = [];
  final List<String> resolveFileCalls = [];
  final List<String> listDirectoryCalls = [];
  var planningBeginCount = 0;
  var planningEndCount = 0;
  var planningAccessActive = false;
  var activePlanningProviderLeaseCount = 0;
  var beginCount = 0;
  var endCount = 0;
  var activeProviderLeaseCount = 0;
  var deleteSourceCalls = 0;
  var partialDestinationCleaned = false;
  var temporaryAlreadyAbsentCount = 0;
  var executionHasStarted = false;
  var _copyCalls = 0;
  var _temporaryCounter = 0;
  var _temporaryCleanupAttempts = 0;
  var _objectCounter = 0;
  Object? _planningToken;
  Set<FileProviderItemReference> _issuedPlanningReferences =
      Set<FileProviderItemReference>.identity();
  String? _lastPinnedSourceIdentity;

  int get temporaryCount => _temporaryArtifacts.length;

  void addFile(String path, String contents) {
    final normalized = p.normalize(path);
    final objectIdentity = 'object-${_objectCounter++}';
    _items[normalized] = _FakeItem(
      reference: FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('controlled-provider'),
        itemIdentity: FileProviderItemIdentity(objectIdentity),
        opaqueItem: normalized,
        itemName: FileProviderItemName.validated(p.basename(normalized)),
        previewPath: FileOperationPreviewPath.single(
          FileProviderItemName.validated(p.basename(normalized)),
        ),
      ),
      bytes: utf8.encode(contents),
      revision: (_items[normalized]?.revision ?? 0) + 1,
      objectIdentity: objectIdentity,
    );
  }

  void removeFile(String path) {
    _items.remove(p.normalize(path));
  }

  void _mutateFileInPlace(String path, String contents) {
    final normalized = p.normalize(path);
    final current = _items[normalized]!;
    _items[normalized] = _FakeItem(
      reference: current.reference,
      bytes: utf8.encode(contents),
      revision: current.revision + 1,
      objectIdentity: current.objectIdentity,
    );
  }

  bool contains(String path) => _items.containsKey(p.normalize(path));

  String contents(String path) => utf8.decode(_items[p.normalize(path)]!.bytes);

  FileProviderItemReference _reference(
    String path, {
    FileOperationPreviewPath? previewPath,
  }) {
    final normalized = p.normalize(path);
    final existing = _items[normalized];
    if (existing != null) {
      final reference = existing.reference;
      return FileProviderItemReference(
        providerIdentity: reference.providerIdentity,
        itemIdentity: reference.itemIdentity,
        opaqueItem: reference.opaqueItem,
        itemName: reference.itemName,
        previewPath: previewPath ?? reference.previewPath,
      );
    }
    final name = FileProviderItemName.validated(p.basename(normalized));
    return FileProviderItemReference(
      providerIdentity: const FileProviderIdentity('controlled-provider'),
      itemIdentity: FileProviderItemIdentity('prospective:$normalized'),
      opaqueItem: normalized,
      itemName: name,
      previewPath: previewPath ?? FileOperationPreviewPath.single(name),
    );
  }

  FileProviderItemReference _issueReference(
    FileProviderItemReference reference,
  ) {
    _issuedPlanningReferences.add(reference);
    return reference;
  }

  FileProviderItemReference issueReferenceForTest(
    FileOperationPlanningAccess access, {
    required String path,
    required FileProviderItemIdentity itemIdentity,
    required FileOperationPreviewPath previewPath,
  }) {
    _requirePlanningAccess(access);
    final name = FileProviderItemName.validated(p.basename(path));
    return _issueReference(
      FileProviderItemReference(
        providerIdentity: const FileProviderIdentity('controlled-provider'),
        itemIdentity: itemIdentity,
        opaqueItem: p.normalize(path),
        itemName: name,
        previewPath: previewPath,
      ),
    );
  }

  void _requirePlanningAccess(FileOperationPlanningAccess access) {
    if (!planningAccessActive ||
        !identical(access.opaqueAccess, _planningToken)) {
      throw StateError('planning access is not active');
    }
  }

  void _requireIssuedPlanningReference(
    FileOperationPlanningAccess access,
    FileProviderItemReference reference,
  ) {
    _requirePlanningAccess(access);
    if (!_issuedPlanningReferences.contains(reference)) {
      throw ArgumentError.value(
        reference.itemIdentity.value,
        'reference',
        'Reference was not issued in this planning scope.',
      );
    }
  }

  _FakeItem _requirePinned(PinnedSourceIdentity source) {
    final item = _items[source.reference.opaqueItem];
    if (item == null ||
        item.reference.itemIdentity.value !=
            source.reference.itemIdentity.value ||
        '${item.revision}' != source.revisionIdentity.value ||
        item.objectIdentity != source.opaquePinnedSource) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    return item;
  }

  @override
  Future<FileOperationPlanningAccess> beginPlanningAccess() async {
    events.add('planningBegin');
    planningBeginCount++;
    activePlanningProviderLeaseCount++;
    if (partialPlanningAccessFailure) {
      activePlanningProviderLeaseCount--;
      throw FileOperationException(FileOperationStatus.unavailableProviderItem);
    }
    planningAccessActive = true;
    _planningToken = Object();
    _issuedPlanningReferences = Set<FileProviderItemReference>.identity();
    return FileOperationPlanningAccess(opaqueAccess: _planningToken!);
  }

  @override
  Future<void> endPlanningAccess(FileOperationPlanningAccess access) async {
    _requirePlanningAccess(access);
    events.add('planningEnd');
    planningEndCount++;
    activePlanningProviderLeaseCount--;
    planningAccessActive = false;
    _planningToken = null;
    _issuedPlanningReferences.clear();
  }

  String _selectionPath(FileProviderSelection selection) {
    expect(selection.providerIdentity.value, 'controlled-provider');
    return p.normalize(selection.opaqueLocator as String);
  }

  @override
  Future<FileProviderItemReference> resolveDirectory(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    _requirePlanningAccess(access);
    events.add('resolveDirectory');
    final path = _selectionPath(selection);
    resolveDirectoryCalls.add(path);
    return _issueReference(_reference(path));
  }

  @override
  Future<FileProviderItemReference> resolveFile(
    FileOperationPlanningAccess access,
    FileProviderSelection selection,
  ) async {
    _requirePlanningAccess(access);
    events.add('resolveFile');
    final path = _selectionPath(selection);
    resolveFileCalls.add(path);
    return _issueReference(_reference(path));
  }

  @override
  Future<List<FileProviderDirectoryEntry>> listDirectory(
    FileOperationPlanningAccess access,
    FileProviderItemReference directory,
  ) async {
    _requireIssuedPlanningReference(access, directory);
    events.add('list');
    if (listingFails) throw StateError('listing failed');
    listDirectoryCalls.add(directory.opaqueItem);
    final parent = p.normalize(directory.opaqueItem);
    return _items.values
        .where((item) => p.dirname(item.reference.opaqueItem) == parent)
        .map((item) {
          final name = item.reference.itemName!;
          return FileProviderDirectoryEntry(
            reference: _issueReference(
              _reference(
                item.reference.opaqueItem,
                previewPath: directory.previewPath.append(name),
              ),
            ),
            name: name,
          );
        })
        .toList();
  }

  @override
  Future<FileProviderItemReference> resolveChild({
    required FileOperationPlanningAccess access,
    required FileProviderItemReference directory,
    required FileProviderItemName relativeName,
  }) async {
    _requireIssuedPlanningReference(access, directory);
    return _issueReference(
      _reference(
        p.join(directory.opaqueItem, relativeName.value),
        previewPath: directory.previewPath.append(relativeName),
      ),
    );
  }

  @override
  Future<bool> locationsEquivalent(
    FileOperationPlanningAccess access,
    FileProviderItemReference left,
    FileProviderItemReference right,
  ) async {
    _requireIssuedPlanningReference(access, left);
    _requireIssuedPlanningReference(access, right);
    return left.providerIdentity.value == right.providerIdentity.value &&
        left.itemIdentity.value == right.itemIdentity.value;
  }

  @override
  Future<bool> previewMetadataMatchesReference(
    FileOperationPlanningAccess access,
    FileProviderItemReference reference,
  ) async {
    _requirePlanningAccess(access);
    if (!_issuedPlanningReferences.contains(reference)) return false;
    var cursor = reference.opaqueItem;
    for (
      var index = reference.previewPath.components.length - 1;
      index >= 0;
      index--
    ) {
      final basename = p.basename(cursor);
      final expected = FileOperationPreviewPath.single(
        FileProviderItemName.validated(basename),
      ).components.single;
      if (reference.previewPath.components[index] != expected) return false;
      cursor = p.dirname(cursor);
    }
    return true;
  }

  @override
  String destinationCollisionKey(FileProviderItemReference destination) {
    return '${destination.providerIdentity.value}:'
        '${destination.opaqueItem.toLowerCase()}';
  }

  @override
  Future<DestinationInspection> inspectDestination(
    FileOperationPlanningAccess access,
    FileProviderItemReference destination,
  ) async {
    _requireIssuedPlanningReference(access, destination);
    events.add('inspectPlanning');
    if (planningInspectionFailure case final status?) {
      throw FileOperationException(status);
    }
    final key = destinationCollisionKey(destination);
    final conflict = _items.values.any(
      (item) => destinationCollisionKey(item.reference) == key,
    );
    return DestinationInspection(
      conflict
          ? DestinationPreflightDisposition.conflict
          : DestinationPreflightDisposition.available,
    );
  }

  @override
  Future<FileOperationAccess> beginOperationAccess(
    FileOperation operation,
  ) async {
    events.add('begin');
    beginCount++;
    executionHasStarted = true;
    if (providerUnavailable) {
      throw FileOperationException(FileOperationStatus.unavailableProviderItem);
    }
    activeProviderLeaseCount += twoScopeReleaseFirstFails ? 2 : 1;
    if (partialAccessFailure) {
      activeProviderLeaseCount--;
      throw FileOperationException(FileOperationStatus.unavailableProviderItem);
    }
    return FileOperationAccess(
      operationId: wrongAccessIdentity ? 'wrong-operation' : operation.id,
      sourceProviderIdentity: operation.source.providerIdentity,
      destinationProviderIdentity: operation.destination.providerIdentity,
      opaqueAccess: Object(),
    );
  }

  @override
  Future<void> endOperationAccess(FileOperationAccess access) async {
    events.add('end');
    endCount++;
    if (twoScopeReleaseFirstFails) {
      events.add('releaseSource');
      activeProviderLeaseCount--;
      events.add('releaseDestination');
      activeProviderLeaseCount--;
      throw StateError('source access release failed');
    }
    activeProviderLeaseCount--;
    if (accessReleaseFails) throw StateError('access release failed');
  }

  @override
  Future<void> requireMutationCapability(
    FileOperationAccess access,
    FileOperation operation,
  ) async {
    events.add('capability');
    if (capabilityClaimsEffects) {
      throw FileOperationException(
        FileOperationStatus.failed,
        destinationState: FileOperationDestinationState.committed,
        sourceState: FileOperationSourceState.deleted,
        temporaryArtifact: FileOperationTemporaryArtifact(
          operationId: operation.id,
          opaqueOriginalLocator: 'forged-locator',
          opaqueIdentity: 'forged-identity',
        ),
        destinationParentState: FileOperationDestinationParentState.created,
      );
    }
    if (capabilityReportsCopied) {
      throw FileOperationException(FileOperationStatus.copied);
    }
    if (capabilityFailure case final status?) {
      throw FileOperationException(status);
    }
  }

  @override
  Future<void> requireTemporaryCleanupCapability(
    FileOperationAccess access,
    FileOperation operation,
    FileOperationTemporaryArtifact temporary,
  ) async {
    events.add('cleanupCapability');
  }

  @override
  Future<FileOperationSourcePinResult> pinSource(
    FileOperationAccess access,
    FileProviderItemReference source,
  ) async {
    events.add('pin');
    final item = _items[source.opaqueItem];
    if (item == null) return const FileOperationSourcePinResult.missing();
    if (item.reference.itemIdentity.value != source.itemIdentity.value) {
      return const FileOperationSourcePinResult.changed();
    }
    _lastPinnedSourceIdentity = source.opaqueItem;
    return FileOperationSourcePinResult.pinned(
      PinnedSourceIdentity(
        reference: source,
        revisionIdentity: FileProviderItemIdentity('${item.revision}'),
        opaquePinnedSource: item.objectIdentity,
      ),
    );
  }

  @override
  Future<FileOperationDestinationPreparationOutcome> ensureDestinationParent(
    FileOperationAccess access,
    FileProviderItemReference destination,
  ) async {
    events.add('prepare');
    if (prepareEnoent) {
      throw const FileSystemException(
        'destination parent disappeared',
        '',
        OSError('No such file or directory', 2),
      );
    }
    if (prepareTypedSourceMissing) {
      throw FileOperationException(FileOperationStatus.sourceMissing);
    }
    if (prepareCreatesThenThrows) {
      throw FileOperationException(
        FileOperationStatus.failed,
        destinationParentState: FileOperationDestinationParentState.created,
      );
    }
    return prepareCreates
        ? FileOperationDestinationPreparationOutcome.created
        : FileOperationDestinationPreparationOutcome.unchanged;
  }

  @override
  Future<FileOperationDestinationReceipt> copyToDestinationExclusively({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileProviderItemReference destination,
  }) async {
    events.add('copy');
    final sourceItem = _requirePinned(source);
    _copyCalls++;
    if (failFirstCopy && _copyCalls == 1) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    if (destinationAppearsDuringCopy) {
      addFile(destination.opaqueItem, 'racer');
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    if (partialWriteEnospc) {
      addFile(destination.opaqueItem, 'partial');
      _items.remove(destination.opaqueItem);
      partialDestinationCleaned = true;
      throw const FileSystemException(
        'exclusive copy failed',
        '',
        OSError('No space left on device', 28),
      );
    }
    await Future<void>.delayed(Duration.zero);
    if (_items.containsKey(destination.opaqueItem)) {
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    _items[destination.opaqueItem] = _FakeItem(
      reference: destination,
      bytes: List.of(sourceItem.bytes),
      revision: 1,
      objectIdentity: 'object-${_objectCounter++}',
    );
    if (copyCloseFailsAfterCommit) {
      throw FileOperationException(
        FileOperationStatus.failed,
        destinationState: FileOperationDestinationState.committed,
      );
    }
    return FileOperationDestinationReceipt.committed(
      operationId: access.operationId,
      destinationIdentity: destination.itemIdentity,
      opaqueReceipt: Object(),
    );
  }

  @override
  Future<FileOperationTemporaryArtifact> createTemporarySibling({
    required FileOperationAccess access,
    required FileProviderItemReference destination,
    required String operationId,
  }) async {
    final counter = _temporaryCounter++;
    final locator = 'temporary-locator-$counter';
    final identity = 'temporary-identity-$counter';
    _temporaryArtifacts[locator] = _FakeTemporary(
      identity: identity,
      bytes: const [],
    );
    final artifact = FileOperationTemporaryArtifact(
      operationId: operationId,
      opaqueOriginalLocator: locator,
      opaqueIdentity: identity,
    );
    if (tempCreateCloseFails) {
      throw FileOperationException(
        FileOperationStatus.failed,
        temporaryArtifact: artifact,
      );
    }
    return artifact;
  }

  @override
  Future<FileOperationTemporaryCopyReceipt> copyToTemporary({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryArtifact temporary,
  }) async {
    events.add('copyTemporary');
    final sourceItem = _requirePinned(source);
    final locator = temporary.opaqueOriginalLocator;
    final owned = _temporaryArtifacts[locator]!;
    if (owned.identity != temporary.opaqueIdentity) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    _temporaryArtifacts[locator] = _FakeTemporary(
      identity: owned.identity,
      bytes: List.of(sourceItem.bytes),
    );
    if (tempCopyThrowsMisplacedConsumedPromotion) {
      throw FileOperationException.promotionCommitted(
        FileOperationStatus.failed,
      );
    }
    if (temporaryCopyEnospc) {
      throw const FileSystemException(
        'temporary copy failed',
        '',
        OSError('No space left on device', 28),
      );
    }
    if (interruptTemporaryCopy) {
      throw FileOperationException(FileOperationStatus.failed);
    }
    if (mutateSourceAfterTemporaryCopy) {
      _mutateFileInPlace(source.reference.opaqueItem, 'BBBB');
    }
    return FileOperationTemporaryCopyReceipt(
      artifact: temporary,
      opaqueReceipt: temporary.opaqueIdentity,
    );
  }

  @override
  Future<void> verifyTemporaryCopy({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
    required FileOperationTemporaryCopyReceipt copy,
  }) async {
    events.add('verify');
    final sourceItem = _requirePinned(source);
    final temporary = _temporaryArtifacts[copy.artifact.opaqueOriginalLocator]!;
    if (temporary.identity != copy.artifact.opaqueIdentity ||
        !_same(temporary.bytes, sourceItem.bytes)) {
      throw FileOperationException(FileOperationStatus.failed);
    }
  }

  @override
  Future<FileOperationDestinationReceipt> promoteTemporaryWithoutReplacement({
    required FileOperationAccess access,
    required FileOperationTemporaryCopyReceipt copy,
    required FileProviderItemReference destination,
  }) async {
    events.add('promote');
    if (promotionEnoent) {
      throw const FileSystemException(
        'destination provider item disappeared',
        '',
        OSError('No such file or directory', 2),
      );
    }
    if (promotionReportsMovedWithoutCommit) {
      throw FileOperationException.promotionNotCommitted(
        FileOperationStatus.moved,
      );
    }
    if (genericPromotionConflict) {
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    if (destinationAppearsDuringPromotion) {
      addFile(destination.opaqueItem, 'racer');
    }
    if (_items.containsKey(destination.opaqueItem)) {
      throw FileOperationException.promotionNotCommitted(
        FileOperationStatus.skippedConflict,
      );
    }
    final temporaryLocator = copy.artifact.opaqueOriginalLocator;
    final temporary = _temporaryArtifacts[temporaryLocator]!;
    _items[destination.opaqueItem] = _FakeItem(
      reference: destination,
      bytes: List.of(temporary.bytes),
      revision: 1,
      objectIdentity: temporary.identity,
    );
    _temporaryArtifacts.remove(temporaryLocator);
    if (mutateSourceAfterPromotion) {
      _mutateFileInPlace(_lastPinnedSourceIdentity!, 'mutation');
    }
    if (replaceSourceAfterPromotion) {
      addFile(_lastPinnedSourceIdentity!, 'replacement');
    }
    if (removeSourceAfterPromotion) {
      removeFile(_lastPinnedSourceIdentity!);
    }
    if (promotionCommitsThenThrows) {
      throw FileOperationException.promotionCommitted(
        FileOperationStatus.failed,
      );
    }
    if (untypedPromotionCommitsThenThrows) {
      throw StateError('untyped provider error after commit');
    }
    if (promotionOutcomeUnknown) {
      _items.remove(destination.opaqueItem);
      throw FileOperationException.promotionUnknown(
        FileOperationStatus.failed,
        temporaryConsumed: true,
      );
    }
    if (malformedPromotionOutcome) {
      throw FileOperationException(
        FileOperationStatus.failed,
        destinationState: FileOperationDestinationState.committed,
      );
    }
    return FileOperationDestinationReceipt.committed(
      operationId: access.operationId,
      destinationIdentity: destination.itemIdentity,
      opaqueReceipt: Object(),
    );
  }

  @override
  Future<FileOperationSourceDeletionOutcome> deleteSourceIfUnchanged({
    required FileOperationAccess access,
    required PinnedSourceIdentity source,
  }) async {
    events.add('deleteSource');
    deleteSourceCalls++;
    if (sourceDeleteConflict) {
      throw FileOperationException(FileOperationStatus.skippedConflict);
    }
    if (sourceDeleteThrows) {
      throw FileOperationException(FileOperationStatus.accessDenied);
    }
    final identity = source.reference.opaqueItem;
    final item = _items[identity];
    if (item == null) return FileOperationSourceDeletionOutcome.missing;
    if ('${item.revision}' != source.revisionIdentity.value ||
        item.objectIdentity != source.opaquePinnedSource) {
      return FileOperationSourceDeletionOutcome.changed;
    }
    _items.remove(identity);
    return FileOperationSourceDeletionOutcome.deleted;
  }

  @override
  Future<FileOperationTemporaryDeletionOutcome> deleteTemporary({
    required FileOperationAccess access,
    required FileOperationTemporaryArtifact temporary,
  }) async {
    events.add('cleanup');
    if (tempCleanupEnoent) {
      throw const FileSystemException(
        'temporary location disappeared',
        '',
        OSError('No such file or directory', 2),
      );
    }
    if (tempCleanupFails || _temporaryCleanupAttempts < tempCleanupFailures) {
      _temporaryCleanupAttempts++;
      throw StateError('temporary cleanup failed');
    }
    final locator = temporary.opaqueOriginalLocator;
    final current = _temporaryArtifacts[locator];
    if (current == null) {
      temporaryAlreadyAbsentCount++;
      return FileOperationTemporaryDeletionOutcome.alreadyAbsent;
    }
    if (tempIdentityChangesBeforeCleanup) {
      _temporaryArtifacts[locator] = _FakeTemporary(
        identity: 'foreign-identity',
        bytes: current.bytes,
      );
    }
    if (_temporaryArtifacts[locator]!.identity != temporary.opaqueIdentity) {
      return FileOperationTemporaryDeletionOutcome.identityChanged;
    }
    _temporaryArtifacts.remove(locator);
    return FileOperationTemporaryDeletionOutcome.deleted;
  }

  @override
  Future<DestinationInspection> inspectDestinationDuringRecovery(
    FileOperationAccess access,
    FileProviderItemReference destination,
  ) async {
    events.add('inspectRecovery');
    if (recoveryInspectionFails && executionHasStarted) {
      throw StateError('inspection unavailable');
    }
    if (recoveryDestinationAppears) {
      addFile(destination.opaqueItem, 'racer');
    }
    final key = destinationCollisionKey(destination);
    final conflict = _items.values.any(
      (item) => destinationCollisionKey(item.reference) == key,
    );
    return DestinationInspection(
      conflict
          ? DestinationPreflightDisposition.conflict
          : DestinationPreflightDisposition.available,
    );
  }
}

class _FakeItem {
  _FakeItem({
    required this.reference,
    required this.bytes,
    required this.revision,
    required this.objectIdentity,
  });

  final FileProviderItemReference reference;
  final List<int> bytes;
  final int revision;
  final String objectIdentity;
}

class _FakeTemporary {
  _FakeTemporary({required this.identity, required this.bytes});

  final String identity;
  final List<int> bytes;
}

bool _same(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class _UnicodeCollisionDartPlatform extends DartFileOperationPlatform {
  const _UnicodeCollisionDartPlatform();

  @override
  String destinationCollisionKey(FileProviderItemReference destination) {
    final normalized = destination.itemIdentity.value
        .toLowerCase()
        .replaceAll('\u00e9', 'e')
        .replaceAll('e\u0301', 'e');
    return '${destination.providerIdentity.value}:$normalized';
  }
}
