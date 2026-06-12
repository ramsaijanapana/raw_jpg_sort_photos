import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../services/file_pick_service.dart';
import '../../services/prefs_service.dart';
import '../../state/cull_controller.dart';

// ---------------------------------------------------------------------------
// Palette constants
// ---------------------------------------------------------------------------

const _keepColor = Color(0xFF3DBE7B);
const _skipColor = Color(0xFFE0564F);

// ---------------------------------------------------------------------------
// Shared image provider helper (spec §1.4)
// ---------------------------------------------------------------------------

ImageProvider stageProvider(Uint8List bytes, int cacheWidth) =>
    ResizeImage(MemoryImage(bytes), width: cacheWidth);

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

  // Key to reach _StageState for zoom toggle from keyboard
  final _stageKey = GlobalKey<_StageState>();

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

  void _showShortcutsDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => const _ShortcutsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cullControllerProvider);
    final ctrl = ref.read(cullControllerProvider.notifier);
    final size = MediaQuery.sizeOf(context);
    final isWide = size.width >= 720;

    // Keep the filmstrip aligned with the current index regardless of what
    // triggered the change (keyboard, swipe, tap, or auto-advance).
    // Also reset the stage transform on index change.
    ref.listen(
      cullControllerProvider.select((s) => s.index),
      (prev, next) {
        _scrollFilmstripTo(next);
        _stageKey.currentState?.resetTransform();
      },
    );

    // Decoded precache for neighbors when index changes.
    ref.listen(
      cullControllerProvider.select((s) => s.index),
      (prev, next) {
        final pairs = state.pairs;
        if (pairs.isEmpty) return;
        final mode = state.mode;
        // Capture context-dependent values before entering async code.
        final size = MediaQuery.sizeOf(context);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final cw = (size.width * dpr).round();
        for (final offset in [1, 2, -1]) {
          final ni = next + offset;
          if (ni < 0 || ni >= pairs.length) continue;
          final key = (stem: pairs[ni].stem, mode: mode);
          ref.read(previewProvider(key).future).then((bytes) {
            if (bytes == null) return;
            if (!mounted) return;
            // ignore: use_build_context_synchronously
            precacheImage(stageProvider(bytes, cw), context);
          });
        }
      },
    );

    Future<void> doOpenFolder() async {
      final svc = ref.read(filePickServiceProvider);
      final result = await svc.pickDirectory(
        title: 'Open photo folder',
      );
      if (result.path != null) {
        await ctrl.openFolder(result.path!);
      }
    }

    return SafeArea(
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: _KeyboardHandler(
          focusNode: _shortcutFocus,
          onNav: ctrl.nav,
          onKeep: ctrl.keep,
          onSkip: ctrl.skip,
          onUnflag: () => ctrl.unflag(),
          onToggleMode: () => ctrl.toggleMode(),
          onFirst: () => ctrl.goto(0),
          onLast: () => ctrl.goto(state.pairs.length - 1),
          onUndo: ctrl.undo,
          onToggleZoom: () => _stageKey.currentState?.toggleZoom(null),
          onShowShortcuts: () => _showShortcutsDialog(context),
          child: Column(
            children: [
              // Top bar
              _TopBar(
                state: state,
                isWide: isWide,
                onOpenFolder: doOpenFolder,
              ),

              // Main stage
              Expanded(
                child: _Stage(
                  key: _stageKey,
                  state: state,
                  isWide: isWide,
                  ctrl: ctrl,
                  onOpenFolder: doOpenFolder,
                ),
              ),

              // Filmstrip
              _Filmstrip(
                state: state,
                controller: _filmstripController,
                itemExtent: _itemExtent,
                onTap: ctrl.goto,
              ),

              // Bottom bar
              _BottomBar(
                state: state,
                isWide: isWide,
                ctrl: ctrl,
                onShowShortcuts: () => _showShortcutsDialog(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shortcuts dialog
// ---------------------------------------------------------------------------

class _ShortcutsDialog extends StatelessWidget {
  const _ShortcutsDialog();

  @override
  Widget build(BuildContext context) {
    const bindings = [
      ('← / →', 'Navigate photos'),
      ('↑ / K', 'Keep'),
      ('↓ / X', 'Skip'),
      ('U', 'Unflag'),
      ('Z / Ctrl+Z', 'Undo'),
      ('R', 'JPG ⇄ RAW'),
      ('Space', 'Zoom 100%'),
      ('Home / End', 'First / Last'),
      ('? (Shift+/)', 'Show this help'),
    ];

    return AlertDialog(
      title: const Text('Keyboard Shortcuts'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (key, desc) in bindings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: Text(
                        key,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Expanded(child: Text(desc)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
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
    required this.onUndo,
    required this.onToggleZoom,
    required this.onShowShortcuts,
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
  final VoidCallback onUndo;
  final VoidCallback onToggleZoom;
  final VoidCallback onShowShortcuts;

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
        const SingleActivator(LogicalKeyboardKey.home): onFirst,
        const SingleActivator(LogicalKeyboardKey.end): onLast,
        // Undo: Z, Ctrl+Z, Meta+Z
        const SingleActivator(LogicalKeyboardKey.keyZ): onUndo,
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): onUndo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): onUndo,
        // Space: toggle zoom
        const SingleActivator(LogicalKeyboardKey.space): onToggleZoom,
        // Shift+/ (?) — show shortcuts
        const SingleActivator(LogicalKeyboardKey.slash, shift: true):
            onShowShortcuts,
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

    final isVeryNarrow = MediaQuery.sizeOf(context).width < 400;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: isWide ? 12 : (isVeryNarrow ? 4 : 8),
          vertical: 4,
        ),
        child: Row(
          children: [
            // Filename
            if (pair != null) ...[
              Flexible(
                child: Text(
                  pair.stem,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // The pair chip is decorative; drop it on narrow widths so the
              // controls fit.
              if (isWide) ...[
                const SizedBox(width: 8),
                _PairChip(hasJpg: pair.jpg != null),
              ],
            ] else
              Flexible(
                child: Text(
                  'No folder open',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            const Spacer(),

            // Counter (hidden on narrow widths to avoid overflow)
            if (isWide && state.pairs.isNotEmpty) ...[
              Text(
                '${state.index + 1} / ${state.pairs.length}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(width: 12),
            ],

            // Mode toggle (compact sizing to avoid overflow on narrow screens).
            if (isVeryNarrow)
              // Under 400px: icon-only toggle to save horizontal space.
              _ModeToggleCompact(
                mode: state.mode,
                onChanged: (m) =>
                    ref.read(cullControllerProvider.notifier).setMode(m),
              )
            else
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'jpg', label: Text('JPG')),
                  ButtonSegment(value: 'raw', label: Text('RAW')),
                ],
                selected: {state.mode},
                onSelectionChanged: (s) =>
                    ref.read(cullControllerProvider.notifier).setMode(s.first),
                style: SegmentedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(36, 30),
                  maximumSize: const Size(120, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),

            // Open folder: full button on wide, compact icon on narrow.
            if (isWide)
              FilledButton(
                onPressed: onOpenFolder,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(100, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Open Folder'),
              )
            else
              IconButton.filled(
                onPressed: onOpenFolder,
                tooltip: 'Open Folder',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  minimumSize: const Size(32, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.all(4),
                ),
                icon: const Icon(Icons.folder_open),
              ),
          ],
        ),
      ),
    );
  }
}

/// Compact mode toggle shown at very narrow widths (<400px).
/// Shows the current mode as text on a small FilledButton.
class _ModeToggleCompact extends StatelessWidget {
  const _ModeToggleCompact({
    required this.mode,
    required this.onChanged,
  });

  final String mode;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final isJpg = mode == 'jpg';
    return GestureDetector(
      onTap: () => onChanged(isJpg ? 'raw' : 'jpg'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          isJpg ? 'JPG' : 'RAW',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSecondaryContainer,
          ),
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

class _Stage extends ConsumerStatefulWidget {
  const _Stage({
    super.key,
    required this.state,
    required this.isWide,
    required this.ctrl,
    required this.onOpenFolder,
  });

  final CullState state;
  final bool isWide;
  final CullController ctrl;
  final VoidCallback onOpenFolder;

  @override
  ConsumerState<_Stage> createState() => _StageState();
}

class _StageState extends ConsumerState<_Stage>
    with SingleTickerProviderStateMixin {
  final _transformController = TransformationController();
  late final AnimationController _animController;
  Animation<Matrix4>? _animation;

  /// Cached position from onDoubleTapDown for the subsequent onDoubleTap.
  Offset? _doubleTapLocalPos;

  /// Native image size, resolved once via ImageStreamListener.
  Size? _nativeImageSize;

  /// Whether the image is effectively un-zoomed; only then should the
  /// horizontal-swipe navigation gesture be active (otherwise pan-while-zoomed
  /// would be hijacked as a swipe).
  bool _atRest = true;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _transformController.addListener(_onTransform);
  }

  void _onTransform() {
    final scale = _transformController.value.getMaxScaleOnAxis();
    final atRest = scale <= 1.05;
    if (atRest != _atRest) {
      setState(() => _atRest = atRest);
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _transformController.removeListener(_onTransform);
    _transformController.dispose();
    super.dispose();
  }

  /// Reset transform to identity (called when navigating to another photo).
  void resetTransform() {
    _animController.stop();
    _animation = null;
    _transformController.value = Matrix4.identity();
    _nativeImageSize = null;
  }

  /// Toggle between fit and 100% zoom, optionally centered on [focalPoint]
  /// in widget-local coordinates.
  void toggleZoom(Offset? focalPoint) {
    final currentScale = _transformController.value.getMaxScaleOnAxis();
    if (currentScale > 1.05) {
      // Return to identity (fit view).
      _animateTo(Matrix4.identity());
    } else {
      // Zoom to 100%: 1 image pixel = 1 device pixel.
      _zoomTo100(focalPoint);
    }
  }

  void _zoomTo100(Offset? focalPoint) {
    final nativeSize = _nativeImageSize;
    if (nativeSize == null) {
      // Image size not known yet; just do a 2x zoom centered.
      _animateTo(Matrix4.diagonal3Values(2.0, 2.0, 1.0));
      return;
    }

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final stageSize = renderBox.size;

    final dpr = MediaQuery.devicePixelRatioOf(context);

    // Scale at which image currently fits the stage.
    final fitScaleX = stageSize.width / nativeSize.width;
    final fitScaleY = stageSize.height / nativeSize.height;
    final fitScale = fitScaleX < fitScaleY ? fitScaleX : fitScaleY;

    // Target: 1 image px = 1 device px → widget scale = dpr / fitScale.
    final targetScale = dpr / fitScale;

    // Center of the stage in widget coords.
    final stageCenter = Offset(stageSize.width / 2, stageSize.height / 2);
    final focal = focalPoint ?? stageCenter;

    // Build the target matrix: scale around focal point.
    // translate(focal) · scale(targetScale) · translate(-focal)
    final matrix = Matrix4.identity()
      ..setEntry(0, 3, focal.dx * (1 - targetScale))
      ..setEntry(1, 3, focal.dy * (1 - targetScale))
      ..setEntry(0, 0, targetScale)
      ..setEntry(1, 1, targetScale);

    _animateTo(matrix);
  }

  void _animateTo(Matrix4 target) {
    _animController.stop();
    _animation = Matrix4Tween(
      begin: _transformController.value,
      end: target,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    ));
    _animation!.addListener(() {
      _transformController.value = _animation!.value;
    });
    _animController.forward(from: 0);
  }

  /// Called when a new image provider is resolved; stores the native image size.
  void _resolveImageSize(ImageProvider provider) {
    final stream = provider.resolve(ImageConfiguration.empty);
    stream.addListener(ImageStreamListener((info, _) {
      if (mounted) {
        setState(() {
          _nativeImageSize = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
      }
    }, onError: (dynamic err, StackTrace? st) {}));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final isWide = widget.isWide;
    final ctrl = widget.ctrl;
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
                  transformController: _transformController,
                  atRest: _atRest,
                  onDoubleTapDown: (pos) => _doubleTapLocalPos = pos,
                  onDoubleTap: () => toggleZoom(_doubleTapLocalPos),
                  onImageResolved: _resolveImageSize,
                  onOpenFolder: widget.onOpenFolder,
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

                // Narrow: swipe (only when un-zoomed) and floating buttons
                if (!isWide && pair != null && _atRest)
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
              tooltip: 'Previous (←)',
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
              tooltip: 'Next (→)',
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

class _StageContent extends ConsumerStatefulWidget {
  const _StageContent({
    required this.state,
    required this.stageWidth,
    required this.devicePixelRatio,
    required this.isWide,
    required this.ctrl,
    required this.transformController,
    required this.atRest,
    required this.onDoubleTapDown,
    required this.onDoubleTap,
    required this.onImageResolved,
    required this.onOpenFolder,
  });

  final CullState state;
  final double stageWidth;
  final double devicePixelRatio;
  final bool isWide;
  final CullController ctrl;
  final TransformationController transformController;
  final bool atRest;
  final void Function(Offset) onDoubleTapDown;
  final VoidCallback onDoubleTap;
  final void Function(ImageProvider) onImageResolved;
  final VoidCallback onOpenFolder;

  @override
  ConsumerState<_StageContent> createState() => _StageContentState();
}

class _StageContentState extends ConsumerState<_StageContent> {
  // Track whether we are zoomed to decide full-res vs bounded decode.
  // We read atRest from the parent via widget.atRest.

  @override
  Widget build(BuildContext context) {
    final pair = widget.state.currentPair;

    if (pair == null && !widget.state.loading) {
      // Check prefs for a saved folder.
      PrefsService? prefs;
      try {
        prefs = ref.read(prefsServiceProvider);
      } catch (_) {
        prefs = null;
      }
      final savedPath = prefs?.lastCullDirIfExists;

      if (savedPath != null) {
        return Center(
          child: _ResumePrompt(
            savedPath: savedPath,
            onResume: () =>
                ref.read(cullControllerProvider.notifier).openFolder(savedPath),
            onOpenFolder: widget.onOpenFolder,
          ),
        );
      }
      return const Center(
        child: Text(
          'Open a folder to start reviewing',
          style: TextStyle(color: Colors.white54),
        ),
      );
    }

    if (widget.state.loading || pair == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final key = (stem: pair.stem, mode: widget.state.mode);
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

        final cacheWidth = (widget.stageWidth * widget.devicePixelRatio).round();

        // Use full-res decode when zoomed, bounded decode when at rest.
        final ImageProvider provider = widget.atRest
            ? stageProvider(bytes, cacheWidth)
            : MemoryImage(bytes);

        // Resolve native image size once for zoom calculations.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onImageResolved(stageProvider(bytes, cacheWidth));
          }
        });

        return GestureDetector(
          onDoubleTapDown: (details) =>
              widget.onDoubleTapDown(details.localPosition),
          onDoubleTap: widget.onDoubleTap,
          child: InteractiveViewer(
            transformationController: widget.transformController,
            maxScale: 8,
            child: Center(
              child: Image(
                image: provider,
                gaplessPlayback: true,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
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

          final flagName = flag == CullFlag.keep
              ? 'keep'
              : flag == CullFlag.skip
              ? 'skip'
              : 'undecided';

          Widget item = Semantics(
            button: true,
            selected: isCurrent,
            label: '${pair.stem}, $flagName',
            child: Column(
              children: [
                GestureDetector(
                  onTap: () => onTap(i),
                  child: Container(
                    width: 64,
                    height: 64,
                    margin:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: borderColor, width: 2),
                    ),
                    child: ClipRect(child: thumb),
                  ),
                ),
                Text(
                  pair.stem,
                  style: Theme.of(context).textTheme.labelSmall,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ],
            ),
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
    required this.onShowShortcuts,
  });

  final CullState state;
  final bool isWide;
  final CullController ctrl;
  final VoidCallback onShowShortcuts;

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
    final total = state.pairs.length;
    final decided = state.decidedCount;
    final isNarrow = MediaQuery.sizeOf(context).width < 400;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Progress bar on top edge (hidden when no folder open)
        if (total > 0)
          LinearProgressIndicator(
            value: total > 0 ? decided / total : 0.0,
            minHeight: 2,
          ),

        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                // Compact flag chips + decided text (all in one Flexible so
                // they shrink/clip before the right-hand controls are pushed off).
                // FittedBox scales content down if the available width is smaller
                // than the natural width of the tally row.
                Flexible(
                  child: total > 0
                      ? FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _FlagChip(
                                icon: '✓',
                                count: state.keptCount,
                                color: _keepColor,
                              ),
                              const SizedBox(width: 3),
                              _FlagChip(
                                icon: '✗',
                                count: state.skipCount,
                                color: _skipColor,
                              ),
                              const SizedBox(width: 3),
                              _FlagChip(
                                icon: '·',
                                count: state.undecidedCount,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '$decided / $total decided',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                  fontFeatures: const [
                                    ui.FontFeature.tabularFigures()
                                  ],
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),

                // Keyboard shortcuts button (hidden on very narrow screens)
                if (!isNarrow)
                  IconButton(
                    icon: const Icon(Icons.keyboard_alt_outlined),
                    tooltip: 'Keyboard shortcuts (?)',
                    iconSize: 20,
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      minimumSize: const Size(32, 32),
                      padding: const EdgeInsets.all(4),
                    ),
                    onPressed: widget.onShowShortcuts,
                  ),

                // Include JPGs control:
                // - very narrow (<400px): FilterChip with compact label
                // - medium (400-720px): checkbox only (no label)
                // - wide (≥720px): checkbox + label
                if (isNarrow)
                  FilterChip(
                    label: const Text('+ JPGs'),
                    selected: _includeJpgs,
                    onSelected: (v) => setState(() => _includeJpgs = v),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: EdgeInsets.zero,
                  )
                else if (widget.isWide) ...[
                  Checkbox(
                    value: _includeJpgs,
                    onChanged: (v) => setState(() => _includeJpgs = v ?? true),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  Text('Also copy JPGs', style: theme.textTheme.bodySmall),
                  const SizedBox(width: 4),
                ] else ...[
                  Checkbox(
                    value: _includeJpgs,
                    onChanged: (v) => setState(() => _includeJpgs = v ?? true),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],

                const SizedBox(width: 2),

                FilledButton(
                  onPressed: state.keptCount == 0 ? null : () => _doExport(context),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(60, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    widget.isWide ? 'Export Kept →' : 'Export →',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _doExport(BuildContext context) async {
    final svc = ref.read(filePickServiceProvider);
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

class _FlagChip extends StatelessWidget {
  const _FlagChip({
    required this.icon,
    required this.count,
    required this.color,
  });

  final String icon;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$icon$count',
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty-state Resume button
// ---------------------------------------------------------------------------

/// Shown in the stage when no folder is open but a previously saved folder
/// exists on disk. Displayed inline via the stage empty content.
class _ResumePrompt extends ConsumerWidget {
  const _ResumePrompt({
    required this.savedPath,
    required this.onResume,
    required this.onOpenFolder,
  });

  final String savedPath;
  final VoidCallback onResume;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseName = p.basename(savedPath);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: onResume,
          icon: const Icon(Icons.history),
          label: Text('Resume $baseName'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: onOpenFolder,
          child: const Text('Open Folder…'),
        ),
      ],
    );
  }
}
