import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_operations.dart';
import '../../state/file_operation_workflow.dart';

typedef FileOperationWorkflowProvider =
    NotifierProvider<
      FileOperationWorkflowController,
      FileOperationWorkflowState
    >;

Future<void> showFileOperationDialog({
  required BuildContext context,
  required FileOperationWorkflowProvider workflowProvider,
  required String title,
  required Future<void> preparation,
}) async {
  unawaited(preparation);
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _FileOperationDialog(workflowProvider: workflowProvider, title: title),
  );
}

class _FileOperationDialog extends ConsumerStatefulWidget {
  const _FileOperationDialog({
    required this.workflowProvider,
    required this.title,
  });

  final FileOperationWorkflowProvider workflowProvider;
  final String title;

  @override
  ConsumerState<_FileOperationDialog> createState() =>
      _FileOperationDialogState();
}

class _FileOperationDialogState extends ConsumerState<_FileOperationDialog> {
  bool _closing = false;

  void _requestClose() {
    if (_closing) return;
    final state = ref.read(widget.workflowProvider);
    final controller = ref.read(widget.workflowProvider.notifier);
    if (state.phase == FileOperationWorkflowPhase.executing) {
      controller.cancel();
      return;
    }
    if (state.cleanupOperationId != null) return;

    _closing = true;
    controller.discard();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(widget.workflowProvider);
    if (state.phase == FileOperationWorkflowPhase.idle && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(widget.workflowProvider).phase ==
            FileOperationWorkflowPhase.idle) {
          Navigator.of(context).pop();
        } else {
          setState(() => _closing = false);
        }
      });
    }
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
          child: SizedBox(
            width: double.maxFinite,
            child: _DialogContent(
              state: state,
              workflowProvider: widget.workflowProvider,
            ),
          ),
        ),
        actions: _actions(state),
      ),
    );
  }

  List<Widget> _actions(FileOperationWorkflowState state) {
    final controller = ref.read(widget.workflowProvider.notifier);
    if (state.phase == FileOperationWorkflowPhase.executing) {
      return [
        OutlinedButton(
          onPressed: controller.cancel,
          child: const Text('Stop safely'),
        ),
      ];
    }
    if (state.cleanupOperationId != null) {
      return const [
        TextButton(onPressed: null, child: Text('Cleanup in progress…')),
      ];
    }
    if (state.phase == FileOperationWorkflowPhase.preview && state.canConfirm) {
      return [
        TextButton(onPressed: _requestClose, child: const Text('Close')),
        FilledButton(
          onPressed: controller.confirm,
          child: Text(_confirmationLabel(state)),
        ),
      ];
    }
    return [TextButton(onPressed: _requestClose, child: const Text('Close'))];
  }
}

class _DialogContent extends StatelessWidget {
  const _DialogContent({required this.state, required this.workflowProvider});

  final FileOperationWorkflowState state;
  final FileOperationWorkflowProvider workflowProvider;

  @override
  Widget build(BuildContext context) {
    switch (state.phase) {
      case FileOperationWorkflowPhase.idle:
      case FileOperationWorkflowPhase.planning:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Preparing a safe file preview…'),
          ],
        );
      case FileOperationWorkflowPhase.preview:
        return _PreviewContent(state: state);
      case FileOperationWorkflowPhase.executing:
      case FileOperationWorkflowPhase.completed:
      case FileOperationWorkflowPhase.cancelled:
        return _ResultsContent(
          state: state,
          workflowProvider: workflowProvider,
        );
      case FileOperationWorkflowPhase.error:
        return Text(
          state.message ??
              'The file preview could not be completed. No files were changed.',
        );
    }
  }
}

class _PreviewContent extends StatelessWidget {
  const _PreviewContent({required this.state});

  final FileOperationWorkflowState state;

  @override
  Widget build(BuildContext context) {
    final operations = state.plan?.operations ?? const <FileOperation>[];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          operations.isEmpty
              ? 'No files are ready to change.'
              : '${state.executableCount} ${_noun(state.executableCount, 'file')} ready'
                    '${state.blockedCount == 0 ? '' : ' · ${state.blockedCount} need attention'}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (state.message != null) ...[
          const SizedBox(height: 12),
          Text(state.message!),
        ],
        if (operations.isNotEmpty) ...[
          const SizedBox(height: 12),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: operations.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final operation = operations[index];
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(operation.preview.source.label),
                  subtitle: Text(operation.preview.destination.label),
                  trailing: Text(
                    operation.preflightStatus == null
                        ? operation.intent == FileOperationIntent.copy
                              ? 'Copy'
                              : 'Move'
                        : _statusLabel(operation.preflightStatus!),
                    textAlign: TextAlign.end,
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _ResultsContent extends ConsumerWidget {
  const _ResultsContent({required this.state, required this.workflowProvider});

  final FileOperationWorkflowState state;
  final FileOperationWorkflowProvider workflowProvider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.phase == FileOperationWorkflowPhase.executing) ...[
          LinearProgressIndicator(
            value: state.total == 0 ? null : state.completed / state.total,
          ),
          const SizedBox(height: 8),
          Text('Applying file ${state.completed} of ${state.total}'),
        ],
        if (state.message != null) ...[
          if (state.phase == FileOperationWorkflowPhase.executing)
            const SizedBox(height: 12),
          Text(state.message!),
        ],
        if (state.reportedResults.isNotEmpty) ...[
          const SizedBox(height: 12),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: state.reportedResults.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final result = state.reportedResults[index];
                final canRetryCleanup =
                    result.effects.temporary ==
                        FileOperationTemporaryState.mayRemain &&
                    result.effects.temporaryArtifact != null;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(result.operation.preview.destination.label),
                  subtitle: result.recovery.isEmpty && !canRetryCleanup
                      ? null
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (result.recovery.isNotEmpty)
                              Text(result.recoveryGuidance),
                            if (canRetryCleanup) ...[
                              const SizedBox(height: 8),
                              OutlinedButton(
                                onPressed: state.cleanupOperationId == null
                                    ? () => ref
                                          .read(workflowProvider.notifier)
                                          .recoverTemporary(result)
                                    : null,
                                child: const Text('Retry temporary cleanup'),
                              ),
                            ],
                          ],
                        ),
                  trailing: Text(_statusLabel(result.status)),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

String _confirmationLabel(FileOperationWorkflowState state) {
  final executable = state.plan!.operations
      .where((operation) => operation.preflightStatus == null)
      .toList(growable: false);
  final intents = executable.map((operation) => operation.intent).toSet();
  final count = executable.length;
  if (intents.length != 1) {
    return 'Apply $count ${_noun(count, 'change')}';
  }
  return switch (intents.single) {
    FileOperationIntent.copy => 'Copy $count ${_noun(count, 'file')}',
    FileOperationIntent.move => 'Move $count ${_noun(count, 'file')}',
  };
}

String _noun(int count, String singular) =>
    count == 1 ? singular : '${singular}s';

String _statusLabel(FileOperationStatus status) => switch (status) {
  FileOperationStatus.copied => 'Copied',
  FileOperationStatus.moved => 'Moved',
  FileOperationStatus.skippedConflict => 'Skipped — destination exists',
  FileOperationStatus.sourceMissing => 'Source missing',
  FileOperationStatus.accessDenied => 'Access denied',
  FileOperationStatus.unavailableProviderItem => 'Provider item unavailable',
  FileOperationStatus.insufficientStorage => 'Not enough storage',
  FileOperationStatus.cancelled => 'Cancelled',
  FileOperationStatus.failed => 'Needs attention',
};
