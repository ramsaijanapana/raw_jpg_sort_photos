import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../state/sort_controller.dart';

class SortScreen extends ConsumerWidget {
  const SortScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(sortControllerProvider);
    final ctrl = ref.read(sortControllerProvider.notifier);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sorting = state.phase == SortPhase.sorting;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header row
                Wrap(
                  spacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Sort Photos',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    _RawJpgChip(),
                  ],
                ),
                const SizedBox(height: 8),
                // Subtitle
                Text(
                  'Separate RAW and JPG files into tidy subfolders.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),

                // Folder pick card
                _FolderPickCard(
                  inputPath: state.inputPath,
                  onTap: sorting ? null : () => ctrl.pickInput(),
                ),
                const SizedBox(height: 20),

                // Output folder row
                _OutputRow(
                  outputPath: state.outputPath,
                  onBrowse: sorting ? null : () => ctrl.pickOutput(),
                ),
                const SizedBox(height: 24),

                // Sort button
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed:
                        sorting || state.inputPath == null
                            ? null
                            : () => ctrl.start(),
                    child: const Text('Sort Photos'),
                  ),
                ),

                // Progress indicator
                if (sorting) ...[
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: state.progress != null
                        ? state.progress!.current / state.progress!.total
                        : null,
                  ),
                  const SizedBox(height: 8),
                  if (state.progress != null)
                    Text(
                      '${state.progress!.fileName}   '
                      '${state.progress!.current} / ${state.progress!.total}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                ],

                const SizedBox(height: 20),

                // Status card
                _StatusCard(state: state),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Chips / sub-widgets
// ---------------------------------------------------------------------------

class _RawJpgChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        'RAW / JPG',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: cs.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _FolderPickCard extends StatelessWidget {
  const _FolderPickCard({
    required this.inputPath,
    required this.onTap,
  });

  final String? inputPath;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasFolder = inputPath != null;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: hasFolder ? cs.primary : cs.outlineVariant,
          width: hasFolder ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.folder_open,
                  color: cs.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: hasFolder
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.basename(inputPath!),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            inputPath!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Choose your photo folder',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Tap to browse',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
              ),
              if (hasFolder)
                Icon(Icons.check_circle, color: Colors.green.shade600),
            ],
          ),
        ),
      ),
    );
  }
}

class _OutputRow extends StatelessWidget {
  const _OutputRow({required this.outputPath, required this.onBrowse});

  final String? outputPath;
  final VoidCallback? onBrowse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              'OUTPUT FOLDER',
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                letterSpacing: 1.0,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                'optional — defaults to input folder',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: InputDecorator(
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: const OutlineInputBorder(),
                  hintText: 'Same as input folder',
                ),
                child: Text(
                  outputPath ?? 'Same as input folder',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color:
                        outputPath == null ? cs.onSurfaceVariant : cs.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onBrowse,
              child: const Text('Browse'),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.state});

  final SortUiState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    switch (state.phase) {
      case SortPhase.idle:
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ready when you are',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Results will appear here after sorting.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        );

      case SortPhase.sorting:
        return const SizedBox.shrink();

      case SortPhase.done:
        final result = state.result!;
        final basename =
            result.outputPath.split(RegExp(r'[/\\]')).last;
        final verb = result.moved ? 'Moved' : 'Copied';

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      color: Colors.green.shade600,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'All done!',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$verb into $basename',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _StatTile(
                        number: '${result.rawCount}',
                        label: 'RAW → RAW/',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _StatTile(
                        number: '${result.jpgCount}',
                        label: 'JPG → JPG/',
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _StatTile(
                        number: '${result.skipped}',
                        label: 'duplicates skipped',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

      case SortPhase.empty:
        return Card(
          color: cs.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  color: cs.onTertiaryContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.message ??
                        'No RAW or JPG files found in the selected folder.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onTertiaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );

      case SortPhase.error:
        return Card(
          color: cs.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                Icon(
                  Icons.error_outline,
                  color: cs.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    state.message ?? 'An unknown error occurred.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
    }
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.number, required this.label});

  final String number;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: cs.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(
            number,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: cs.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSecondaryContainer,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
