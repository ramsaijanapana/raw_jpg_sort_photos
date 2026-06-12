import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../services/file_pick_service.dart';
import '../../state/cull_controller.dart';

// ---------------------------------------------------------------------------
// Palette constants
// ---------------------------------------------------------------------------

const _keepColor = Color(0xFF3DBE7B);
const _skipColor = Color(0xFFE0564F);

// ---------------------------------------------------------------------------
// Root screen
// ---------------------------------------------------------------------------

class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key, this.active = true});

  /// Whether this page is the one currently shown by the shell's
  /// IndexedStack. Drives keyboard-focus acquisition.
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F8EF7),
      brightness: Brightness.dark,
    );

    return Theme(
      data: ThemeData(
        colorScheme: darkScheme,
        useMaterial3: true,
      ),
      child: _ReviewBody(active: active),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

class _ReviewBody extends ConsumerStatefulWidget {
  const _ReviewBody({required this.active});

  final bool active;

  @override
  ConsumerState<_ReviewBody> createState() => _ReviewBodyState();
}

class _ReviewBodyState extends ConsumerState<_ReviewBody> {
  final _filmstripController = ScrollController();
  final _shortcutFocus = FocusNode(debugLabel: 'review-shortcuts');
  static const double _itemExtent = 68.0;

  @override
  void initState() {
    super.initState();
    _claimFocusIfActive();
  }

  @override
  void didUpdateWidget(_ReviewBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _claimFocusIfActive();
  }

  /// The shell keeps pages alive in an IndexedStack, so autofocus alone is
  /// unreliable: claim keyboard focus post-frame whenever this page becomes
  /// the visible one (the node must be attached before requestFocus works).
  void _claimFocusIfActive() {
    if (!widget.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) _shortcutFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _shortcutFocus.dispose();
    _filmstripController.dispose();
    super.dispose();
  }

  void _scrollFilmstripTo(int index) {
    if (!_filmstripController.hasClients) return;
    final viewport = _filmstripController.position.viewportDimension;
    final offset =
        (index * _itemExtent) - (viewport / 2 - _itemExtent / 2);
    _filmstripController.animateTo(
      offset.clamp(0.0, _filmstripController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cullControllerProvider);
    final ctrl = ref.read(cullControllerProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 720;

    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: _KeyboardHandler(
        focusNode: _shortcutFocus,
        onNav: (d) {
          ctrl.nav(d);
          _scrollFilmstripTo(state.index + d);
        },
        onKeep: () async {
          await ctrl.keep();
          _scrollFilmstripTo(state.index);
        },
        onSkip: () async {
          await ctrl.skip();
          _scrollFilmstripTo(state.index);
        },
        onUnflag: () => ctrl.unflag(),
        onToggleMode: () => ctrl.toggleMode(),
        onFirst: () {
          ctrl.goto(0);
          _scrollFilmstripTo(0);
        },
        onLast: () {
          final last = state.pairs.length - 1;
          ctrl.goto(last);
          _scrollFilmstripTo(last);
        },
        child: Column(
          children: [
            // Top bar
            _TopBar(
              state: state,
              isWide: isWide,
              onOpenFolder: () async {
                final svc = FilePickService();
                final result = await svc.pickDirectory(
                  title: 'Open photo folder',
                );
                if (result.path != null) {
                  await ctrl.openFolder(result.path!);
                  _scrollFilmstripTo(0);
                }
              },
            ),

            // Main stage
            Expanded(
              child: _Stage(state: state, isWide: isWide, ctrl: ctrl),
            ),

            // Filmstrip
            _Filmstrip(
              state: state,
              controller: _filmstripController,
              itemExtent: _itemExtent,
              onTap: (i) {
                ctrl.goto(i);
                _scrollFilmstripTo(i);
              },
            ),

            // Bottom bar
            _BottomBar(
              state: state,
              isWide: isWide,
              ctrl: ctrl,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Keyboard shortcuts wrapper
// ---------------------------------------------------------------------------

class _KeyboardHandler extends StatelessWidget {
  const _KeyboardHandler({
    required this.child,
    required this.focusNode,
    required this.onNav,
    required this.onKeep,
    required this.onSkip,
    required this.onUnflag,
    required this.onToggleMode,
    required this.onFirst,
    required this.onLast,
  });

  final Widget child;
  final FocusNode focusNode;
  final void Function(int) onNav;
  final VoidCallback onKeep;
  final VoidCallback onSkip;
  final VoidCallback onUnflag;
  final VoidCallback onToggleMode;
  final VoidCallback onFirst;
  final VoidCallback onLast;

  @override
  Widget build(BuildContext context) {
    // CallbackShortcuts must be the ANCESTOR of the focused node: key events
    // bubble up from the primary focus through its ancestors, so the inverse
    // nesting (Focus outside CallbackShortcuts) never receives any event.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => onNav(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => onNav(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): onKeep,
        const SingleActivator(LogicalKeyboardKey.keyK): onKeep,
        const SingleActivator(LogicalKeyboardKey.arrowDown): onSkip,
        const SingleActivator(LogicalKeyboardKey.keyX): onSkip,
        const SingleActivator(LogicalKeyboardKey.keyU): onUnflag,
        const SingleActivator(LogicalKeyboardKey.keyR): onToggleMode,
        const SingleActivator(LogicalKeyboardKey.tab): onToggleMode,
        const SingleActivator(LogicalKeyboardKey.home): onFirst,
        const SingleActivator(LogicalKeyboardKey.end): onLast,
      },
      child: Focus(
        focusNode: focusNode,
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: focusNode.requestFocus,
          child: child,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Top bar
// ---------------------------------------------------------------------------

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.state,
    required this.isWide,
    required this.onOpenFolder,
  });

  final CullState state;
  final bool isWide;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final pair = state.currentPair;

    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // Filename
            if (pair != null) ...[
              Text(
                pair.stem,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              _PairChip(hasJpg: pair.jpg != null),
            ] else
              Text(
                'No folder open',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            const Spacer(),

            // Counter
            if (state.pairs.isNotEmpty) ...[
              Text(
                '${state.index + 1} / ${state.pairs.length}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 12),
            ],

            // Mode toggle
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'jpg', label: Text('JPG')),
                ButtonSegment(value: 'raw', label: Text('RAW')),
              ],
              selected: {state.mode},
              onSelectionChanged: (s) =>
                  ref.read(cullControllerProvider.notifier).setMode(s.first),
              style: SegmentedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(60, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(width: 8),

            // Open folder
            FilledButton(
              onPressed: onOpenFolder,
              style: FilledButton.styleFrom(
                minimumSize: const Size(100, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Open Folder'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairChip extends StatelessWidget {
  const _PairChip({required this.hasJpg});

  final bool hasJpg;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: hasJpg
            ? cs.secondaryContainer
            : const Color(0xFFFFB300).withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        hasJpg ? 'RAW + JPG' : 'RAW only',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: hasJpg ? cs.onSecondaryContainer : const Color(0xFFFFB300),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stage
// ---------------------------------------------------------------------------

class _Stage extends ConsumerWidget {
  const _Stage({
    required this.state,
    required this.isWide,
    required this.ctrl,
  });

  final CullState state;
  final bool isWide;
  final CullController ctrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pair = state.currentPair;
    final flag = pair != null
        ? (state.flags[pair.stem] ?? CullFlag.undecided)
        : CullFlag.undecided;

    final stageWidget = LayoutBuilder(
      builder: (context, constraints) {
        final stageW = constraints.maxWidth;
        final dpr = MediaQuery.devicePixelRatioOf(context);

        return Container(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                // Main content
                _StageContent(
                  state: state,
                  stageWidth: stageW,
                  devicePixelRatio: dpr,
                  isWide: isWide,
                  ctrl: ctrl,
                ),

                // Left flag stripe
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 5,
                    color: pair == null
                        ? Colors.transparent
                        : flag == CullFlag.keep
                        ? _keepColor
                        : flag == CullFlag.skip
                        ? _skipColor
                        : Colors.transparent,
                  ),
                ),

                // Flag badge
                if (pair != null && flag != CullFlag.undecided)
                  Positioned(
                    top: 12,
                    left: 16,
                    child: _FlagBadge(flag: flag),
                  ),

                // Narrow: swipe and floating buttons
                if (!isWide && pair != null)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onHorizontalDragEnd: (details) {
                        final v = details.primaryVelocity ?? 0;
                        if (v < -200) ctrl.nav(1);
                        if (v > 200) ctrl.nav(-1);
                      },
                    ),
                  ),
                if (!isWide && pair != null)
                  Positioned(
                    bottom: 16,
                    left: 0,
                    right: 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: () => ctrl.keep(),
                          style: FilledButton.styleFrom(
                            backgroundColor: _keepColor,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Keep'),
                        ),
                        const SizedBox(width: 16),
                        FilledButton(
                          onPressed: () => ctrl.skip(),
                          style: FilledButton.styleFrom(
                            backgroundColor: _skipColor,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('Skip'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (isWide) {
      return Row(
        children: [
          // Left chevron
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: IconButton.filledTonal(
              icon: const Icon(Icons.chevron_left),
              onPressed:
                  state.index > 0 ? () => ctrl.nav(-1) : null,
            ),
          ),

          // Stage area
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(8),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
              ),
              child: stageWidget,
            ),
          ),

          // Right chevron
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: IconButton.filledTonal(
              icon: const Icon(Icons.chevron_right),
              onPressed:
                  state.pairs.isNotEmpty && state.index < state.pairs.length - 1
                      ? () => ctrl.nav(1)
                      : null,
            ),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.all(8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
      ),
      child: stageWidget,
    );
  }
}

class _StageContent extends ConsumerWidget {
  const _StageContent({
    required this.state,
    required this.stageWidth,
    required this.devicePixelRatio,
    required this.isWide,
    required this.ctrl,
  });

  final CullState state;
  final double stageWidth;
  final double devicePixelRatio;
  final bool isWide;
  final CullController ctrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pair = state.currentPair;

    if (pair == null) {
      return const Center(
        child: Text(
          'Open a folder to start reviewing',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    if (state.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final key = (stem: pair.stem, mode: state.mode);
    final previewAsync = ref.watch(previewProvider(key));

    return previewAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          'Preview error: $e',
          style: const TextStyle(color: Colors.red),
        ),
      ),
      data: (bytes) {
        if (bytes == null) {
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_not_supported, color: Colors.white38, size: 48),
                SizedBox(height: 8),
                Text(
                  'No preview available',
                  style: TextStyle(color: Colors.white38),
                ),
              ],
            ),
          );
        }

        final cacheWidth = (stageWidth * devicePixelRatio).round();

        return InteractiveViewer(
          maxScale: 8,
          child: Center(
            child: Image.memory(
              bytes,
              gaplessPlayback: true,
              fit: BoxFit.contain,
              cacheWidth: cacheWidth,
            ),
          ),
        );
      },
    );
  }
}

class _FlagBadge extends StatelessWidget {
  const _FlagBadge({required this.flag});

  final CullFlag flag;

  @override
  Widget build(BuildContext context) {
    final isKeep = flag == CullFlag.keep;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: (isKeep ? _keepColor : _skipColor).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        isKeep ? '✓ KEEP' : '✗ SKIP',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Filmstrip
// ---------------------------------------------------------------------------

class _Filmstrip extends ConsumerWidget {
  const _Filmstrip({
    required this.state,
    required this.controller,
    required this.itemExtent,
    required this.onTap,
  });

  final CullState state;
  final ScrollController controller;
  final double itemExtent;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.pairs.isEmpty) return const SizedBox(height: 92);

    return SizedBox(
      height: 92,
      child: ListView.builder(
        controller: controller,
        scrollDirection: Axis.horizontal,
        itemCount: state.pairs.length,
        itemExtent: itemExtent,
        itemBuilder: (context, i) {
          final pair = state.pairs[i];
          final flag = state.flags[pair.stem] ?? CullFlag.undecided;
          final isCurrent = i == state.index;

          final thumbAsync = ref.watch(thumbnailProvider(pair.stem));
          Widget thumb = thumbAsync.when(
            loading: () => const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (err, st) => const Icon(Icons.broken_image, size: 24),
            data: (bytes) => bytes != null
                ? Image.memory(
                    bytes,
                    cacheWidth: 128,
                    cacheHeight: 128,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  )
                : const Icon(Icons.image_not_supported, size: 24),
          );

          final cs = Theme.of(context).colorScheme;
          final borderColor = isCurrent
              ? cs.primary
              : flag == CullFlag.keep
              ? _keepColor
              : flag == CullFlag.skip
              ? _skipColor
              : cs.outlineVariant;

          Widget item = Column(
            children: [
              GestureDetector(
                onTap: () => onTap(i),
                child: Container(
                  width: 64,
                  height: 64,
                  margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  decoration: BoxDecoration(
                    border: Border.all(color: borderColor, width: 2),
                  ),
                  child: ClipRect(child: thumb),
                ),
              ),
              Text(
                pair.stem.length > 8
                    ? pair.stem.substring(pair.stem.length - 8)
                    : pair.stem,
                style: Theme.of(context).textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          );

          if (flag == CullFlag.skip) {
            item = Opacity(opacity: 0.45, child: item);
          }

          return item;
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom bar
// ---------------------------------------------------------------------------

class _BottomBar extends ConsumerStatefulWidget {
  const _BottomBar({
    required this.state,
    required this.isWide,
    required this.ctrl,
  });

  final CullState state;
  final bool isWide;
  final CullController ctrl;

  @override
  ConsumerState<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends ConsumerState<_BottomBar> {
  bool _includeJpgs = true;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final cs = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            // Tally + keyboard hint (wrapped in Flexible so they can shrink)
            Flexible(
              child: Text(
                widget.isWide
                    ? '✓ ${state.keptCount} kept   '
                        '✗ ${state.skipCount} skipped   '
                        '· ${state.undecidedCount} undecided'
                        '     ← → navigate   ↑ keep   ↓ skip   U unflag   R raw/jpg'
                    : '✓ ${state.keptCount} kept   '
                        '✗ ${state.skipCount} skipped   '
                        '· ${state.undecidedCount} undecided',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            const Spacer(),

            // Include JPGs checkbox
            Checkbox(
              value: _includeJpgs,
              onChanged: (v) => setState(() => _includeJpgs = v ?? true),
              visualDensity: VisualDensity.compact,
            ),
            Text('Also copy JPGs', style: theme.textTheme.bodySmall),
            const SizedBox(width: 12),

            // Export button
            FilledButton(
              onPressed: state.keptCount == 0
                  ? null
                  : () => _doExport(context),
              style: FilledButton.styleFrom(
                minimumSize: const Size(100, 34),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Export Kept →'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doExport(BuildContext context) async {
    final svc = FilePickService();
    final result = await svc.pickDirectory(title: 'Export kept photos to…');

    if (!context.mounted) return;

    if (result.warning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.warning!)),
      );
      return;
    }

    if (result.path == null) return;

    try {
      final exportResult = await widget.ctrl.export(
        destinationPath: result.path!,
        includeJpgs: _includeJpgs,
      );

      if (!context.mounted) return;
      final basename = p.basename(exportResult.outputPath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied ${exportResult.copied} files → $basename'),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }
}
