import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_sorter/core/file_operations.dart';
import 'package:photo_sorter/core/models.dart';
import 'package:photo_sorter/services/file_pick_service.dart';
import 'package:photo_sorter/services/prefs_service.dart';
import 'package:photo_sorter/state/cull_controller.dart';
import 'package:photo_sorter/state/file_operation_workflow.dart';
import 'package:photo_sorter/state/sort_controller.dart';
import 'package:photo_sorter/ui/file_operation/file_operation_dialog.dart';
import 'package:photo_sorter/ui/review/review_screen.dart';
import 'package:photo_sorter/ui/sort/sort_screen.dart';

import 'support/controlled_file_operation_platform.dart';

void main() {
  Future<PrefsService> mockPrefs([
    Map<String, Object> initial = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(initial);
    return PrefsService(await SharedPreferences.getInstance());
  }

  Future<FileOperationPlan> controlledPlan(
    ControlledFileOperationPlatform platform, {
    required List<
      ({
        String source,
        List<String> sourcePreview,
        String destination,
        List<String> destinationPreview,
        FileOperationIntent intent,
      })
    >
    descriptions,
  }) {
    return planFileOperations(
      platform: platform,
      buildOperations: (access) async {
        return [
          for (final description in descriptions)
            FileOperation.create(
              source: await platform.resolveFile(
                access,
                platform.selection(
                  description.source,
                  previewComponents: description.sourcePreview,
                ),
              ),
              destination: await platform.resolveFile(
                access,
                platform.selection(
                  description.destination,
                  previewComponents: description.destinationPreview,
                ),
              ),
              intent: description.intent,
            ),
        ];
      },
    );
  }

  Future<void> pumpDialogLauncher(
    WidgetTester tester,
    ProviderContainer container, {
    required Future<FileOperationPlan> Function() buildPlan,
    String title = 'Review file changes',
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  final preparation = container
                      .read(sortFileOperationWorkflowProvider.notifier)
                      .prepare((_) => buildPlan());
                  await showFileOperationDialog(
                    context: context,
                    workflowProvider: sortFileOperationWorkflowProvider,
                    title: title,
                    preparation: preparation,
                  );
                },
                child: const Text('Open preview'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> sendRawDesktopDrop(Offset location, String path) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      'desktop_drop',
      codec.encodeMethodCall(
        MethodCall('entered', <double>[location.dx, location.dy]),
      ),
      (_) {},
    );
    await messenger.handlePlatformMessage(
      'desktop_drop',
      codec.encodeMethodCall(MethodCall('performOperation', <String>[path])),
      (_) {},
    );
  }

  Future<void> waitForWorkflowPhase(
    ProviderContainer container,
    FileOperationWorkflowProvider provider,
    FileOperationWorkflowPhase phase,
  ) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (container.read(provider).phase != phase) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Workflow did not reach $phase.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  testWidgets('sort action is explicitly a preview action', (tester) async {
    final input = Directory.systemTemp.createTempSync('sort_ui_input_');
    addTearDown(() => input.deleteSync(recursive: true));
    File(p.join(input.path, 'photo.arw')).writeAsStringSync('source');
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(
          await mockPrefs({'lastSortInput': input.path}),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SortScreen()),
      ),
    );
    await tester.pump();

    expect(find.widgetWithText(FilledButton, 'Preview Sort'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Sort Photos'), findsNothing);
  });

  testWidgets(
    'sort controls and desktop drop unregister for every active phase',
    (tester) async {
      final input = Directory.systemTemp.createTempSync(
        'sort_lifecycle_input_',
      );
      addTearDown(() => input.deleteSync(recursive: true));
      File(p.join(input.path, 'photo.arw')).writeAsStringSync('source');
      final workflow = _ManualWorkflowController();
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(
            await mockPrefs({'lastSortInput': input.path}),
          ),
          sortFileOperationWorkflowProvider.overrideWith(() => workflow),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SortScreen()),
        ),
      );
      await tester.pump();
      container.read(sortFileOperationWorkflowProvider);
      expect(find.byType(DropTarget), findsOneWidget);

      final activeStates = [
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.planning),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.preview),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.executing),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.completed),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.cancelled),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.error),
        FileOperationWorkflowState(
          phase: FileOperationWorkflowPhase.completed,
          cleanupOperationId: 'cleanup-in-flight',
        ),
      ];

      for (final active in activeStates) {
        workflow.publish(active);
        await tester.pump();
        expect(
          find.byType(DropTarget),
          findsNothing,
          reason: '${active.phase}',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Preview Sort'),
              )
              .onPressed,
          isNull,
          reason: '${active.phase}',
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Browse'))
              .onPressed,
          isNull,
          reason: '${active.phase}',
        );
      }

      workflow.publish(FileOperationWorkflowState());
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SortScreen(active: false)),
        ),
      );
      await tester.pump();
      expect(find.byType(DropTarget), findsNothing, reason: 'inactive page');
    },
  );

  testWidgets(
    'raw desktop drops cannot bypass sort preview or terminal overlay routes',
    (tester) async {
      final input = Directory.systemTemp.createTempSync('sort_raw_drop_input_');
      final replacement = Directory.systemTemp.createTempSync(
        'sort_raw_drop_replacement_',
      );
      addTearDown(() {
        input.deleteSync(recursive: true);
        replacement.deleteSync(recursive: true);
      });
      File(p.join(input.path, 'photo.arw')).writeAsStringSync('source');
      File(p.join(replacement.path, 'other.arw')).writeAsStringSync('other');
      final platform = ControlledFileOperationPlatform(
        acceptDartSelections: true,
      )..addFile(p.join(input.path, 'photo.arw'), 'source');
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(
            await mockPrefs({'lastSortInput': input.path}),
          ),
          fileOperationBackendProvider.overrideWithValue(
            FileOperationBackend(
              platform: platform,
              canExecute: true,
              unavailableMessage: 'Unavailable.',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SortScreen()),
        ),
      );
      await tester.pump();
      final dropLocation = tester.getCenter(find.byType(DropTarget));

      await tester.tap(find.widgetWithText(FilledButton, 'Preview Sort'));
      await tester.runAsync(
        () => waitForWorkflowPhase(
          container,
          sortFileOperationWorkflowProvider,
          FileOperationWorkflowPhase.preview,
        ),
      );
      await tester.pump();
      expect(find.text('Review sort changes'), findsOneWidget);
      expect(find.byType(DropTarget), findsNothing);
      expect(
        container.read(sortFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.preview,
      );

      await sendRawDesktopDrop(dropLocation, replacement.path);
      await tester.pump();
      expect(container.read(sortControllerProvider).inputPath, input.path);
      expect(find.text('Review sort changes'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Move 1 file'));
      await tester.runAsync(
        () => waitForWorkflowPhase(
          container,
          sortFileOperationWorkflowProvider,
          FileOperationWorkflowPhase.completed,
        ),
      );
      await tester.pump();
      expect(
        container.read(sortFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.completed,
      );
      expect(find.text('Moved'), findsOneWidget);
      expect(find.byType(DropTarget), findsNothing);

      await sendRawDesktopDrop(dropLocation, replacement.path);
      await tester.pump();
      expect(container.read(sortControllerProvider).inputPath, input.path);
      expect(find.text('Review sort changes'), findsOneWidget);
      expect(find.text('Moved'), findsOneWidget);
    },
  );

  testWidgets(
    'preview-only dialog shows safe breadcrumbs and no confirmation action',
    (tester) async {
      final platform = ControlledFileOperationPlatform()
        ..addFile('opaque-source-SENTINEL', 'source');
      final plan = await controlledPlan(
        platform,
        descriptions: [
          (
            source: 'opaque-source-SENTINEL',
            sourcePreview: ['Camera Card', 'safe.arw'],
            destination: 'opaque-destination-SENTINEL',
            destinationPreview: ['Chosen Folder', 'safe.arw'],
            intent: FileOperationIntent.copy,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          fileOperationBackendProvider.overrideWithValue(
            FileOperationBackend(
              platform: platform,
              canExecute: false,
              unavailableMessage:
                  'This version can preview file changes but cannot apply '
                  'them yet. No files were changed.',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async {
                    final preparation = container
                        .read(sortFileOperationWorkflowProvider.notifier)
                        .prepare((_) async => plan);
                    await showFileOperationDialog(
                      context: context,
                      workflowProvider: sortFileOperationWorkflowProvider,
                      title: 'Review file changes',
                      preparation: preparation,
                    );
                  },
                  child: const Text('Open preview'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open preview'));
      await tester.pumpAndSettle();

      expect(find.text('Review file changes'), findsOneWidget);
      expect(find.text('Camera Card/safe.arw'), findsOneWidget);
      expect(find.text('Chosen Folder/safe.arw'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(
        find.text(
          'This version can preview file changes but cannot apply them yet. '
          'No files were changed.',
        ),
        findsOneWidget,
      );
      expect(find.text('Copy 1 file'), findsNothing);
      expect(find.textContaining('SENTINEL'), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Review file changes'), findsNothing);
      expect(
        container.read(sortFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.idle,
      );
    },
  );

  testWidgets(
    'mixed confirmation is explicit, double tap is one execution, and terminal closes',
    (tester) async {
      final platform = ControlledFileOperationPlatform()
        ..addFile('copy-source.arw', 'copy')
        ..addFile('move-source.jpg', 'move');
      final plan = await controlledPlan(
        platform,
        descriptions: [
          (
            source: 'copy-source.arw',
            sourcePreview: ['Input', 'copy-source.arw'],
            destination: 'copy-destination.arw',
            destinationPreview: ['Output', 'copy-destination.arw'],
            intent: FileOperationIntent.copy,
          ),
          (
            source: 'move-source.jpg',
            sourcePreview: ['Input', 'move-source.jpg'],
            destination: 'move-destination.jpg',
            destinationPreview: ['Output', 'move-destination.jpg'],
            intent: FileOperationIntent.move,
          ),
        ],
      );
      final container = ProviderContainer(
        overrides: [
          fileOperationBackendProvider.overrideWithValue(
            FileOperationBackend(
              platform: platform,
              canExecute: true,
              unavailableMessage: 'Unavailable.',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await pumpDialogLauncher(tester, container, buildPlan: () async => plan);
      await tester.tap(find.text('Open preview'));
      await tester.pumpAndSettle();

      final confirm = find.widgetWithText(FilledButton, 'Apply 2 changes');
      expect(confirm, findsOneWidget);
      await tester.tap(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();

      expect(platform.beginOperationCount, 2);
      expect(platform.contents('copy-destination.arw'), 'copy');
      expect(platform.contents('move-destination.jpg'), 'move');
      expect(platform.contains('move-source.jpg'), isFalse);
      expect(find.text('Copied'), findsOneWidget);
      expect(find.text('Moved'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Review file changes'), findsNothing);
      expect(
        container.read(sortFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.idle,
      );
    },
  );

  testWidgets('back during execution requests cancellation and stays visible', (
    tester,
  ) async {
    final mutationGate = Completer<void>();
    final platform = ControlledFileOperationPlatform(mutationGate: mutationGate)
      ..addFile('first.arw', 'first')
      ..addFile('second.arw', 'second');
    final plan = await controlledPlan(
      platform,
      descriptions: [
        for (final name in ['first', 'second'])
          (
            source: '$name.arw',
            sourcePreview: ['Input', '$name.arw'],
            destination: 'sorted-$name.arw',
            destinationPreview: ['Output', 'sorted-$name.arw'],
            intent: FileOperationIntent.copy,
          ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: true,
            unavailableMessage: 'Unavailable.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(tester, container, buildPlan: () async => plan);
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Copy 2 files'));
    await tester.pump();
    await tester.runAsync(() => platform.mutationStarted.future);

    await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('Review file changes'), findsOneWidget);
    expect(
      container.read(sortFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.executing,
    );
    expect(
      find.text('Stopping safely after the current file…'),
      findsOneWidget,
    );

    mutationGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Review file changes'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Review file changes'), findsNothing);
    expect(
      container.read(sortFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.idle,
    );
  });

  testWidgets('temporary cleanup retry is identity-bound and single-flight', (
    tester,
  ) async {
    final cleanupGate = Completer<void>();
    final platform = ControlledFileOperationPlatform(
      temporaryCopyFailure: true,
      retainTemporaryOnInitialCleanup: true,
      cleanupGate: cleanupGate,
    )..addFile('source.arw', 'source');
    final plan = await controlledPlan(
      platform,
      descriptions: [
        (
          source: 'source.arw',
          sourcePreview: ['Input', 'source.arw'],
          destination: 'destination.arw',
          destinationPreview: ['Output', 'destination.arw'],
          intent: FileOperationIntent.move,
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: true,
            unavailableMessage: 'Unavailable.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(tester, container, buildPlan: () async => plan);
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move 1 file'));
    await tester.pumpAndSettle();

    final retry = find.text('Retry temporary cleanup');
    expect(retry, findsOneWidget);
    await tester.tap(retry);
    await tester.tap(retry);
    await tester.pump();
    await tester.runAsync(() => platform.recoveryCleanupStarted.future);
    expect(platform.cleanupCount, 2);
    final disabledRetry = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Retry temporary cleanup'),
    );
    expect(disabledRetry.onPressed, isNull);

    cleanupGate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Retry temporary cleanup'), findsNothing);
    final result = container
        .read(sortFileOperationWorkflowProvider)
        .execution!
        .results
        .single;
    expect(result.effects.temporary, FileOperationTemporaryState.cleaned);
    expect(platform.cleanupCount, 2);
  });

  testWidgets('planning dismissal invalidates a late preview and closes', (
    tester,
  ) async {
    final platform = ControlledFileOperationPlatform()
      ..addFile('source.arw', 'source');
    final plan = await controlledPlan(
      platform,
      descriptions: [
        (
          source: 'source.arw',
          sourcePreview: ['Input', 'source.arw'],
          destination: 'destination.arw',
          destinationPreview: ['Output', 'destination.arw'],
          intent: FileOperationIntent.copy,
        ),
      ],
    );
    final latePlan = Completer<FileOperationPlan>();
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(
      tester,
      container,
      buildPlan: () => latePlan.future,
    );
    await tester.tap(find.text('Open preview'));
    await tester.pump();
    expect(find.text('Preparing a safe file preview…'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Review file changes'), findsNothing);
    latePlan.complete(plan);
    await tester.pump();

    final state = container.read(sortFileOperationWorkflowProvider);
    expect(state.phase, FileOperationWorkflowPhase.idle);
    expect(state.plan, isNull);
  });

  testWidgets('external idle invalidation closes a mounted planning dialog', (
    tester,
  ) async {
    final platform = ControlledFileOperationPlatform();
    final emptyPlan = await controlledPlan(platform, descriptions: const []);
    final latePlan = Completer<FileOperationPlan>();
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(
      tester,
      container,
      buildPlan: () => latePlan.future,
    );
    await tester.tap(find.text('Open preview'));
    await tester.pump();
    expect(find.text('Review file changes'), findsOneWidget);

    container.read(sortFileOperationWorkflowProvider.notifier).discard();
    await tester.pumpAndSettle();

    expect(find.text('Review file changes'), findsNothing);
    expect(find.text('Open preview'), findsOneWidget);
    latePlan.complete(emptyPlan);
    await tester.pump();
  });

  testWidgets('planning exception text never reaches the dialog', (
    tester,
  ) async {
    final platform = ControlledFileOperationPlatform();
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(
      tester,
      container,
      buildPlan: () async =>
          throw StateError('/private/provider/SENTINEL-EXCEPTION'),
    );
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not prepare a file preview. No files were changed.'),
      findsOneWidget,
    );
    expect(find.textContaining('SENTINEL-EXCEPTION'), findsNothing);
    expect(find.textContaining('/private/provider'), findsNothing);
  });

  testWidgets('blocked files are excluded from the confirmation count', (
    tester,
  ) async {
    final platform = ControlledFileOperationPlatform()
      ..addFile('ready-source.arw', 'ready')
      ..addFile('blocked-source.arw', 'blocked')
      ..setInspection(
        'blocked-destination.arw',
        DestinationPreflightDisposition.conflict,
      );
    final plan = await controlledPlan(
      platform,
      descriptions: [
        (
          source: 'ready-source.arw',
          sourcePreview: ['Input', 'ready-source.arw'],
          destination: 'ready-destination.arw',
          destinationPreview: ['Output', 'ready-destination.arw'],
          intent: FileOperationIntent.copy,
        ),
        (
          source: 'blocked-source.arw',
          sourcePreview: ['Input', 'blocked-source.arw'],
          destination: 'blocked-destination.arw',
          destinationPreview: ['Output', 'blocked-destination.arw'],
          intent: FileOperationIntent.copy,
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: true,
            unavailableMessage: 'Unavailable.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(tester, container, buildPlan: () async => plan);
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();

    expect(find.text('1 file ready · 1 need attention'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Copy 1 file'), findsOneWidget);
    expect(find.text('Skipped — destination exists'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Copy 1 file'));
    await tester.pumpAndSettle();

    expect(platform.beginOperationCount, 1);
    expect(find.text('Copied'), findsOneWidget);
    expect(find.text('Skipped — destination exists'), findsOneWidget);
    expect(platform.contents('ready-destination.arw'), 'ready');
    expect(platform.contains('blocked-destination.arw'), isFalse);
  });

  testWidgets(
    'Preview Export opens the shared preview instead of direct export',
    (tester) async {
      final source = Directory.systemTemp.createTempSync(
        'review_export_source_',
      );
      final destination = Directory.systemTemp.createTempSync(
        'review_export_destination_',
      );
      addTearDown(() {
        source.deleteSync(recursive: true);
        destination.deleteSync(recursive: true);
      });
      File(p.join(source.path, 'A.ARW')).writeAsStringSync('raw');
      File(p.join(source.path, 'A.JPG')).writeAsStringSync('jpg');
      final platform = ControlledFileOperationPlatform(
        acceptDartSelections: true,
      );
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(await mockPrefs()),
          filePickServiceProvider.overrideWithValue(
            _FixedFilePickService(destination.path),
          ),
          fileOperationBackendProvider.overrideWithValue(
            FileOperationBackend(
              platform: platform,
              canExecute: false,
              unavailableMessage: 'Preview only. No files were changed.',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReviewScreen()),
        ),
      );
      await tester.runAsync(() async {
        final controller = container.read(cullControllerProvider.notifier);
        await controller.openFolder(source.path);
        await controller.keep();
      });
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Preview Export →'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      try {
        final previewExport = find.semantics.byLabel('Preview Export');
        expect(previewExport, findsOneWidget);
        expect(
          previewExport.evaluate().single.getSemanticsData().hasAction(
            SemanticsAction.tap,
          ),
          isTrue,
        );
        tester.semantics.tap(previewExport);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      } finally {
        semantics.dispose();
      }

      expect(find.text('Review export changes'), findsOneWidget);
      expect(find.text('A.ARW'), findsWidgets);
      expect(find.text('A.JPG'), findsWidgets);
      expect(find.text('Preview only. No files were changed.'), findsOneWidget);
      expect(
        container.read(exportFileOperationWorkflowProvider).phase,
        FileOperationWorkflowPhase.preview,
      );
      expect(File(p.join(destination.path, 'A.ARW')).existsSync(), isFalse);
      expect(File(p.join(destination.path, 'A.JPG')).existsSync(), isFalse);
    },
  );

  testWidgets(
    'review folder selection, export, and drop unregister for active export or loading',
    (tester) async {
      final source = Directory.systemTemp.createTempSync(
        'review_lifecycle_source_',
      );
      addTearDown(() {
        source.deleteSync(recursive: true);
      });
      File(p.join(source.path, 'CURRENT.ARW')).writeAsStringSync('current');

      final workflow = _ManualWorkflowController();
      final initialCull = CullState(
        dir: source,
        pairs: [
          PhotoPair(
            stem: 'CURRENT',
            raw: File(p.join(source.path, 'CURRENT.ARW')),
          ),
        ],
        flags: const {'CURRENT': CullFlag.keep},
      );
      final cull = _ManualCullController(initialCull);
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(await mockPrefs()),
          exportFileOperationWorkflowProvider.overrideWith(() => workflow),
          cullControllerProvider.overrideWith(() => cull),
        ],
      );
      addTearDown(container.dispose);
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReviewScreen()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      container.read(exportFileOperationWorkflowProvider);

      final activeStates = [
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.planning),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.preview),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.executing),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.completed),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.cancelled),
        FileOperationWorkflowState(phase: FileOperationWorkflowPhase.error),
        FileOperationWorkflowState(
          phase: FileOperationWorkflowPhase.completed,
          cleanupOperationId: 'cleanup-in-flight',
        ),
      ];

      for (final active in activeStates) {
        workflow.publish(active);
        await tester.pump();
        expect(
          find.byType(DropTarget),
          findsNothing,
          reason: '${active.phase}',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Open Folder'),
              )
              .onPressed,
          isNull,
          reason: '${active.phase}',
        );
        expect(
          tester.widget<Checkbox>(find.byType(Checkbox)).onChanged,
          isNull,
          reason: '${active.phase}',
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Preview Export →'),
              )
              .onPressed,
          isNull,
          reason: '${active.phase}',
        );
      }

      workflow.publish(FileOperationWorkflowState());
      cull.publish(initialCull.copyWith(loading: true));
      await tester.pump();
      expect(container.read(cullControllerProvider).loading, isTrue);

      expect(find.byType(DropTarget), findsNothing, reason: 'loading');
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Open Folder'),
            )
            .onPressed,
        isNull,
        reason: 'loading',
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox)).onChanged,
        isNull,
        reason: 'loading',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Preview Export →'),
            )
            .onPressed,
        isNull,
        reason: 'loading',
      );
      final semantics = tester.ensureSemantics();
      try {
        final previewExport = find.semantics.byLabel('Preview Export');
        expect(previewExport, findsOneWidget);
        expect(
          previewExport.evaluate().single.getSemanticsData().hasAction(
            SemanticsAction.tap,
          ),
          isFalse,
        );
      } finally {
        semantics.dispose();
      }

      cull.publish(initialCull);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReviewScreen(active: false)),
        ),
      );
      await tester.pump();
      expect(find.byType(DropTarget), findsNothing, reason: 'inactive page');
    },
  );

  testWidgets('destination chooser locks every export selection input', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_destination_lock_source_',
    );
    addTearDown(() => source.deleteSync(recursive: true));
    File(p.join(source.path, 'A.ARW')).writeAsStringSync('A');
    final container = ProviderContainer(
      overrides: [prefsServiceProvider.overrideWithValue(await mockPrefs())],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    expect(find.byType(DropTarget), findsOneWidget);

    expect(controller.beginExportIntent(), isNotNull);
    await tester.pump();

    expect(find.byType(DropTarget), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Open Folder'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Preview Export →'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
    expect(controller.beginOpenFolderSelection(), isNull);
  });

  testWidgets(
    'duplicate export semantics taps open only one destination chooser',
    (tester) async {
      final source = Directory.systemTemp.createTempSync(
        'review_single_export_picker_source_',
      );
      final destination = Directory.systemTemp.createTempSync(
        'review_single_export_picker_destination_',
      );
      addTearDown(() {
        source.deleteSync(recursive: true);
        destination.deleteSync(recursive: true);
      });
      File(p.join(source.path, 'A.ARW')).writeAsStringSync('A');
      final picker = _ControlledFilePickService();
      final container = ProviderContainer(
        overrides: [
          prefsServiceProvider.overrideWithValue(await mockPrefs()),
          filePickServiceProvider.overrideWithValue(picker),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(cullControllerProvider.notifier);
      await tester.runAsync(() async {
        await controller.openFolder(source.path);
        await controller.keep();
      });
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReviewScreen()),
        ),
      );
      await tester.pump();

      final semantics = tester.ensureSemantics();
      try {
        final previewExport = find.semantics.byLabel('Preview Export');
        tester.semantics.tap(previewExport);
        tester.semantics.tap(previewExport);
        await tester.pump();
      } finally {
        semantics.dispose();
      }
      expect(picker.calls, 1);

      picker.complete(destination.path);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Review export changes'), findsOneWidget);
    },
  );

  testWidgets('disposing review cancels its pending destination intent', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_disposed_picker_source_',
    );
    final destination = Directory.systemTemp.createTempSync(
      'review_disposed_picker_destination_',
    );
    addTearDown(() {
      source.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'A.ARW')).writeAsStringSync('A');
    final picker = _ControlledFilePickService();
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(await mockPrefs()),
        filePickServiceProvider.overrideWithValue(picker),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Preview Export →'),
        )
        .onPressed!();
    await tester.pump();
    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isTrue,
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isFalse,
    );

    picker.complete(destination.path);
    await tester.pump();
    expect(
      container.read(exportFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.idle,
    );
    expect(find.text('Review export changes'), findsNothing);
  });

  testWidgets('chooser cancellation and failure release the retained intent', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_chooser_release_source_',
    );
    final destination = Directory.systemTemp.createTempSync(
      'review_chooser_release_destination_',
    );
    addTearDown(() {
      source.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'A.ARW')).writeAsStringSync('A');
    final picker = _QueuedControlledFilePickService(3);
    final platform = ControlledFileOperationPlatform(
      acceptDartSelections: true,
    );
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(await mockPrefs()),
        filePickServiceProvider.overrideWithValue(picker),
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only. No files were changed.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );

    FilledButton previewButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Preview Export →'),
    );

    previewButton().onPressed!();
    await tester.pump();
    picker.cancel(0);
    await tester.pump();
    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isFalse,
    );
    expect(previewButton().onPressed, isNotNull);

    previewButton().onPressed!();
    await tester.pump();
    picker.fail(1, StateError('/private/hostile/chooser-secret'));
    await tester.pump();
    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isFalse,
    );
    expect(previewButton().onPressed, isNotNull);
    expect(
      find.text(
        'The destination chooser could not be opened. No files were changed.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('chooser-secret'), findsNothing);

    previewButton().onPressed!();
    await tester.pump();
    picker.complete(2, destination.path);
    await tester.runAsync(
      () => waitForWorkflowPhase(
        container,
        exportFileOperationWorkflowProvider,
        FileOperationWorkflowPhase.preview,
      ),
    );
    await tester.pump();
    expect(find.text('Review export changes'), findsOneWidget);
  });

  testWidgets('an older disposed chooser cannot cancel a newer export intent', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_disposed_chooser_aba_source_',
    );
    final staleDestination = Directory.systemTemp.createTempSync(
      'review_disposed_chooser_aba_stale_',
    );
    final currentDestination = Directory.systemTemp.createTempSync(
      'review_disposed_chooser_aba_current_',
    );
    addTearDown(() {
      source.deleteSync(recursive: true);
      staleDestination.deleteSync(recursive: true);
      currentDestination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'A.ARW')).writeAsStringSync('A');
    final picker = _QueuedControlledFilePickService(2);
    final platform = ControlledFileOperationPlatform(
      acceptDartSelections: true,
    );
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(await mockPrefs()),
        filePickServiceProvider.overrideWithValue(picker),
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only. No files were changed.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);

    Future<void> pumpReview() => tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );

    await pumpReview();
    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Preview Export →'),
        )
        .onPressed!();
    await tester.pump();
    expect(picker.calls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();
    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isFalse,
    );

    await pumpReview();
    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Preview Export →'),
        )
        .onPressed!();
    await tester.pump();
    expect(picker.calls, 2);
    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isTrue,
    );

    picker.complete(0, staleDestination.path);
    await tester.pump();
    expect(
      container.read(cullControllerProvider).exportDestinationPending,
      isTrue,
    );
    expect(
      container.read(exportFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.idle,
    );

    picker.complete(1, currentDestination.path);
    await tester.runAsync(
      () => waitForWorkflowPhase(
        container,
        exportFileOperationWorkflowProvider,
        FileOperationWorkflowPhase.preview,
      ),
    );
    await tester.pump();
    expect(
      container.read(exportFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.preview,
    );
  });

  testWidgets(
    'failed folder replacement is visible and cannot export the old folder',
    (tester) async {
      final source = Directory.systemTemp.createTempSync(
        'review_failed_open_source_',
      );
      addTearDown(() => source.deleteSync(recursive: true));
      File(p.join(source.path, 'OLD.ARW')).writeAsStringSync('old');
      final container = ProviderContainer(
        overrides: [prefsServiceProvider.overrideWithValue(await mockPrefs())],
      );
      addTearDown(container.dispose);
      final controller = container.read(cullControllerProvider.notifier);
      await tester.runAsync(() async {
        await controller.openFolder(source.path);
        await controller.keep();
      });
      tester.view.physicalSize =
          const Size(1100, 760) * tester.view.devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReviewScreen()),
        ),
      );

      final missing = p.join(source.parent.path, 'missing-photo-folder');
      await tester.runAsync(() => controller.openFolder(missing));
      await tester.pump();

      expect(
        find.text('Could not open that folder. Choose a folder and try again.'),
        findsOneWidget,
      );
      expect(find.textContaining(missing), findsNothing);
      expect(find.text('No folder open'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Preview Export →'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('delayed export destination locks out folder replacement', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_export_intent_source_',
    );
    final replacement = Directory.systemTemp.createTempSync(
      'review_export_intent_replacement_',
    );
    final destination = Directory.systemTemp.createTempSync(
      'review_export_intent_destination_',
    );
    addTearDown(() {
      source.deleteSync(recursive: true);
      replacement.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'SOURCE.ARW')).writeAsStringSync('source');
    File(
      p.join(replacement.path, 'REPLACEMENT.ARW'),
    ).writeAsStringSync('replacement');
    File(
      p.join(replacement.path, 'cull_session.json'),
    ).writeAsStringSync('{"REPLACEMENT":"keep"}');

    final picker = _ControlledFilePickService();
    final platform = ControlledFileOperationPlatform(
      acceptDartSelections: true,
    );
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(await mockPrefs()),
        filePickServiceProvider.overrideWithValue(picker),
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only. No files were changed.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final previewExport = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Preview Export →'),
    );
    previewExport.onPressed!();
    await tester.pump();
    expect(picker.started.isCompleted, isTrue);
    await tester.runAsync(() => controller.openFolder(replacement.path));
    expect(container.read(cullControllerProvider).dir!.path, source.path);

    picker.complete(destination.path);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      container.read(exportFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.preview,
    );
    expect(find.text('Review export changes'), findsOneWidget);
    expect(
      container
          .read(exportFileOperationWorkflowProvider)
          .plan!
          .operations
          .map((operation) => operation.source.itemName!.value),
      ['SOURCE.ARW'],
    );
  });

  testWidgets('delayed export destination locks the kept selection', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_export_keep_intent_source_',
    );
    final destination = Directory.systemTemp.createTempSync(
      'review_export_keep_intent_destination_',
    );
    addTearDown(() {
      source.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'A.ARW')).writeAsStringSync('A');
    File(p.join(source.path, 'B.ARW')).writeAsStringSync('B');

    final picker = _ControlledFilePickService();
    final platform = ControlledFileOperationPlatform(
      acceptDartSelections: true,
    );
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(await mockPrefs()),
        filePickServiceProvider.overrideWithValue(picker),
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only. No files were changed.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      controller.goto(0);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Preview Export →'),
        )
        .onPressed!();
    await tester.pump();
    expect(picker.started.isCompleted, isTrue);
    await tester.runAsync(() async {
      controller.goto(0);
      await controller.unflag();
      controller.goto(1);
      await controller.keep();
    });
    final locked = container.read(cullControllerProvider);
    expect(locked.flags['A'], CullFlag.keep);
    expect(locked.flags['B'], isNull);

    picker.complete(destination.path);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(
      container.read(exportFileOperationWorkflowProvider).phase,
      FileOperationWorkflowPhase.preview,
    );
    expect(find.text('Review export changes'), findsOneWidget);
    expect(
      container
          .read(exportFileOperationWorkflowProvider)
          .plan!
          .operations
          .map((operation) => operation.source.itemName!.value),
      ['A.ARW'],
    );
  });

  testWidgets('delayed export captures the include-JPG choice at invocation', (
    tester,
  ) async {
    final source = Directory.systemTemp.createTempSync(
      'review_export_jpg_intent_source_',
    );
    final destination = Directory.systemTemp.createTempSync(
      'review_export_jpg_intent_destination_',
    );
    addTearDown(() {
      source.deleteSync(recursive: true);
      destination.deleteSync(recursive: true);
    });
    File(p.join(source.path, 'A.ARW')).writeAsStringSync('raw');
    File(p.join(source.path, 'A.JPG')).writeAsStringSync('jpg');

    final picker = _ControlledFilePickService();
    final platform = ControlledFileOperationPlatform(
      acceptDartSelections: true,
    );
    final container = ProviderContainer(
      overrides: [
        prefsServiceProvider.overrideWithValue(await mockPrefs()),
        filePickServiceProvider.overrideWithValue(picker),
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only. No files were changed.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(cullControllerProvider.notifier);
    await tester.runAsync(() async {
      await controller.openFolder(source.path);
      await controller.keep();
    });
    tester.view.physicalSize =
        const Size(1100, 760) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ReviewScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Preview Export →'),
        )
        .onPressed!();
    await tester.pump();
    expect(picker.started.isCompleted, isTrue);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    picker.complete(destination.path);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    final workflow = container.read(exportFileOperationWorkflowProvider);
    expect(workflow.phase, FileOperationWorkflowPhase.preview);
    expect(
      workflow.plan!.operations
          .map((operation) => operation.source.itemName!.value)
          .toList(),
      ['A.ARW', 'A.JPG'],
    );
  });

  testWidgets('preview dialog fits a 360-point screen with long file names', (
    tester,
  ) async {
    tester.view.physicalSize =
        const Size(360, 700) * tester.view.devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    final platform = ControlledFileOperationPlatform();
    final descriptions =
        <
          ({
            String source,
            List<String> sourcePreview,
            String destination,
            List<String> destinationPreview,
            FileOperationIntent intent,
          })
        >[];
    for (var index = 0; index < 8; index++) {
      final source = 'source-$index.arw';
      final destination = 'destination-$index.arw';
      platform.addFile(source, 'source');
      descriptions.add((
        source: source,
        sourcePreview: [
          'Camera Card',
          'A_VERY_LONG_RAW_FILENAME_THAT_MUST_WRAP_$index.ARW',
        ],
        destination: destination,
        destinationPreview: [
          'Chosen Folder',
          'A_VERY_LONG_RAW_FILENAME_THAT_MUST_WRAP_$index.ARW',
        ],
        intent: FileOperationIntent.copy,
      ));
    }
    final plan = await controlledPlan(platform, descriptions: descriptions);
    final container = ProviderContainer(
      overrides: [
        fileOperationBackendProvider.overrideWithValue(
          FileOperationBackend(
            platform: platform,
            canExecute: false,
            unavailableMessage: 'Preview only. No files were changed.',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await pumpDialogLauncher(tester, container, buildPlan: () async => plan);
    await tester.tap(find.text('Open preview'));
    await tester.pumpAndSettle();

    expect(find.text('Review file changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _ManualWorkflowController extends FileOperationWorkflowController {
  @override
  FileOperationWorkflowState build() => FileOperationWorkflowState();

  void publish(FileOperationWorkflowState next) => state = next;
}

final class _ManualCullController extends CullController {
  _ManualCullController(this.initial);

  final CullState initial;

  @override
  CullState build() => initial;

  void publish(CullState next) => state = next;
}

final class _ControlledFilePickService extends FilePickService {
  final started = Completer<void>();
  final _result = Completer<PickResult>();
  var calls = 0;

  @override
  Future<PickResult> pickDirectory({String? title}) async {
    calls++;
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete(String path) {
    _result.complete((path: path, warning: null));
  }
}

final class _QueuedControlledFilePickService extends FilePickService {
  _QueuedControlledFilePickService(int count)
    : _results = List.generate(count, (_) => Completer<PickResult>());

  final List<Completer<PickResult>> _results;
  var calls = 0;

  @override
  Future<PickResult> pickDirectory({String? title}) {
    return _results[calls++].future;
  }

  void complete(int index, String path) {
    _results[index].complete((path: path, warning: null));
  }

  void cancel(int index) {
    _results[index].complete((path: null, warning: null));
  }

  void fail(int index, Object error) {
    _results[index].completeError(error);
  }
}

final class _FixedFilePickService extends FilePickService {
  _FixedFilePickService(this.path);

  final String path;

  @override
  Future<PickResult> pickDirectory({String? title}) async {
    return (path: path, warning: null);
  }
}
