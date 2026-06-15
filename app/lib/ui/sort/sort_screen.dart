import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
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
                // Header row (no chip)
                Text(
                  'Sort Photos',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
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

                // Folder pick card (hero + drop zone)
                _FolderPickCard(
                  inputPath: state.inputPath,
                  onTap: sorting ? null : () => ctrl.pickInput(),
                  onDropPath: sorting ? null : (path) => ctrl.setInput(path),
                ),
                const SizedBox(height: 20),

                // Output folder row
                _OutputRow(
                  outputPath: state.outputPath,
                  onBrowse: sorting ? null : () => ctrl.pickOutput(),
                ),
                const SizedBox(height: 24),

                // Sort button or Cancel button
                SizedBox(
                  height: 52,
                  child: sorting
                      ? OutlinedButton(
                          onPressed: () => ctrl.cancel(),
                          child: const Text('Cancel'),
                        )
                      : FilledButton(
                          onPressed: state.inputPath == null
                              ? null
                              : () => ctrl.start(),
                          child: const Text('Sort Photos'),
                        ),
                ),

                // "Choose a folder to enable" hint when disabled
                if (!sorting && state.inputPath == null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Choose a folder to enable',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],

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

                // Status card (no idle card)
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
// Folder pick card with drop zone
// ---------------------------------------------------------------------------

class _FolderPickCard extends StatefulWidget {
  const _FolderPickCard({
    required this.inputPath,
    required this.onTap,
    required this.onDropPath,
  });

  final String? inputPath;
  final VoidCallback? onTap;
  final void Function(String path)? onDropPath;

  @override
  State<_FolderPickCard> createState() => _FolderPickCardState();
}

class _FolderPickCardState extends State<_FolderPickCard> {
  bool _dragging = false;

  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  void _handleDrop(DropDoneDetails details) {
    if (widget.onDropPath == null) return;
    final files = details.files;
    if (files.isEmpty) return;
    final first = files.first.path;
    // If it's a directory use it directly; otherwise use parent.
    final dir = Directory(first);
    if (dir.existsSync()) {
      widget.onDropPath!(first);
    } else {
      widget.onDropPath!(p.dirname(first));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final hasFolder = widget.inputPath != null;

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      constraints: const BoxConstraints(minHeight: 140),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _dragging
              ? cs.primary
              : hasFolder
                  ? cs.primary
                  : cs.outline,
          width: _dragging ? 2.0 : (hasFolder ? 2.0 : 1.5),
        ),
        color: _dragging
            ? cs.primary.withValues(alpha: 0.08)
            : theme.colorScheme.surface,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _dragging
              ? _DropHint(cs: cs)
              : hasFolder
                  ? _FolderContent(
                      inputPath: widget.inputPath!,
                      theme: theme,
                      cs: cs,
                    )
                  : _EmptyContent(
                      theme: theme,
                      cs: cs,
                      isDesktop: _isDesktop,
                    ),
        ),
      ),
    );

    if (_isDesktop) {
      card = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) {
          setState(() => _dragging = false);
          _handleDrop(details);
        },
        child: card,
      );
    }

    return card;
  }
}

class _DropHint extends StatelessWidget {
  const _DropHint({required this.cs});
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: cs.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.drive_folder_upload_outlined,
              color: cs.onPrimaryContainer),
        ),
        const SizedBox(width: 16),
        Text(
          'Drop folder to sort',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _FolderContent extends StatelessWidget {
  const _FolderContent({
    required this.inputPath,
    required this.theme,
    required this.cs,
  });
  final String inputPath;
  final ThemeData theme;
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.folder_open, color: cs.onSecondaryContainer),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.basename(inputPath),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                inputPath,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        Icon(Icons.check_circle, color: Colors.green.shade600),
      ],
    );
  }
}

class _EmptyContent extends StatelessWidget {
  const _EmptyContent({
    required this.theme,
    required this.cs,
    required this.isDesktop,
  });
  final ThemeData theme;
  final ColorScheme cs;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.create_new_folder_outlined,
            color: cs.onSecondaryContainer,
            size: 32,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose your photo folder',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                isDesktop
                    ? 'Click to browse — or drop a folder here'
                    : 'Tap to browse',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
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
                'optional',
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
        // No idle card — show nothing.
        return const SizedBox.shrink();

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

      case SortPhase.cancelled:
        return Card(
          color: cs.tertiaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sort stopped',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onTertiaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  state.message ?? 'Sort was cancelled.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onTertiaryContainer,
                  ),
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
