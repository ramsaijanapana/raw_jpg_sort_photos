import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/cull_session.dart';
import '../core/exporter.dart';
import '../core/models.dart';
import '../core/raw_preview/raw_preview_extractor.dart';
import '../core/scanner.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class CullState {
  const CullState({
    this.dir,
    this.pairs = const [],
    this.flags = const {},
    this.index = 0,
    this.mode = 'jpg',
    this.loading = false,
    this.error,
  });

  final Directory? dir;
  final List<PhotoPair> pairs;
  final Map<String, CullFlag> flags;
  final int index;
  final String mode; // 'jpg' | 'raw'
  final bool loading;
  final String? error;

  CullState copyWith({
    Object? dir = _sentinel,
    List<PhotoPair>? pairs,
    Map<String, CullFlag>? flags,
    int? index,
    String? mode,
    bool? loading,
    Object? error = _sentinel,
  }) {
    return CullState(
      dir: dir == _sentinel ? this.dir : dir as Directory?,
      pairs: pairs ?? this.pairs,
      flags: flags ?? this.flags,
      index: index ?? this.index,
      mode: mode ?? this.mode,
      loading: loading ?? this.loading,
      error: error == _sentinel ? this.error : error as String?,
    );
  }

  static const _sentinel = Object();

  // Derived
  PhotoPair? get currentPair =>
      pairs.isNotEmpty && index < pairs.length ? pairs[index] : null;

  int get keptCount =>
      flags.values.where((f) => f == CullFlag.keep).length;

  int get skipCount =>
      flags.values.where((f) => f == CullFlag.skip).length;

  int get undecidedCount =>
      pairs.length - keptCount - skipCount;
}

// ---------------------------------------------------------------------------
// LRU cache helper
// ---------------------------------------------------------------------------

class _LruCache<K, V> {
  _LruCache(this.capacity);

  final int capacity;
  final LinkedHashMap<K, V> _map = LinkedHashMap();

  V? get(K key) {
    final val = _map.remove(key);
    if (val != null) _map[key] = val;
    return val;
  }

  void put(K key, V value) {
    _map.remove(key);
    if (_map.length >= capacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = value;
  }

  bool containsKey(K key) => _map.containsKey(key);
}

// ---------------------------------------------------------------------------
// Preview cache provider (module-level singleton via provider)
// ---------------------------------------------------------------------------

/// Holds a preview LRU keyed by (stem, mode).
class PreviewCache {
  final _lru = _LruCache<({String stem, String mode}), Uint8List?>(12);
}

final previewCacheProvider = Provider<PreviewCache>((_) => PreviewCache());

// ---------------------------------------------------------------------------
// Preview FutureProvider.family
// ---------------------------------------------------------------------------

typedef PreviewKey = ({String stem, String mode});

final previewProvider = FutureProvider.family<Uint8List?, PreviewKey>(
  (ref, key) async {
    final cache = ref.read(previewCacheProvider);
    if (cache._lru.containsKey(key)) {
      return cache._lru.get(key);
    }

    final ctrl = ref.read(cullControllerProvider);
    final pair = ctrl.pairs.firstWhere(
      (p) => p.stem == key.stem,
      orElse: () => throw StateError('Pair not found: ${key.stem}'),
    );

    Uint8List? bytes;
    if (key.mode == 'jpg' && pair.jpg != null) {
      bytes = await pair.jpg!.readAsBytes();
    } else {
      bytes = await extractPreview(pair.raw);
    }

    cache._lru.put(key, bytes);
    return bytes;
  },
);

// ---------------------------------------------------------------------------
// Thumbnail FutureProvider.family
// ---------------------------------------------------------------------------

final thumbnailProvider = FutureProvider.family<Uint8List?, String>(
  (ref, stem) async {
    final ctrl = ref.read(cullControllerProvider);
    final pair = ctrl.pairs.firstWhere(
      (p) => p.stem == stem,
      orElse: () => throw StateError('Pair not found: $stem'),
    );

    if (pair.jpg != null) {
      return pair.jpg!.readAsBytes();
    }
    return extractPreview(pair.raw);
  },
);

// ---------------------------------------------------------------------------
// CullController Notifier
// ---------------------------------------------------------------------------

class CullController extends Notifier<CullState> {
  @override
  CullState build() => const CullState();

  Future<void> openFolder(String path) async {
    state = state.copyWith(loading: true, error: null);

    try {
      final dir = Directory(path);
      final pairs = await scanPairs(dir);
      pairs.sort((a, b) => a.stem.compareTo(b.stem));
      final session = await CullSession.load(dir);

      state = state.copyWith(
        dir: dir,
        pairs: pairs,
        flags: Map.unmodifiable(Map<String, CullFlag>.from(session.flags)),
        index: 0,
        loading: false,
        error: null,
      );

      _preloadNeighbors(0);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'Failed to open folder: $e',
      );
    }
  }

  void goto(int index) {
    final clamped = index.clamp(0, state.pairs.length - 1);
    state = state.copyWith(index: clamped);
    _preloadNeighbors(clamped);
  }

  void nav(int delta) => goto(state.index + delta);

  Future<void> keep() async {
    await _setFlag(CullFlag.keep);
    _autoAdvance();
  }

  Future<void> skip() async {
    await _setFlag(CullFlag.skip);
    _autoAdvance();
  }

  Future<void> unflag() async {
    await _setFlag(CullFlag.undecided);
  }

  void toggleMode() {
    state = state.copyWith(mode: state.mode == 'jpg' ? 'raw' : 'jpg');
  }

  void setMode(String mode) {
    state = state.copyWith(mode: mode);
  }

  Future<ExportResult> export({
    required String destinationPath,
    required bool includeJpgs,
  }) async {
    final dir = state.dir;
    if (dir == null) throw StateError('No folder open');

    final session = _buildSession();
    return exportKept(
      source: dir,
      destination: Directory(destinationPath),
      pairs: state.pairs,
      session: session,
      includeJpgs: includeJpgs,
    );
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<void> _setFlag(CullFlag flag) async {
    final pair = state.currentPair;
    if (pair == null) return;

    final newFlags = Map<String, CullFlag>.from(state.flags);
    if (flag == CullFlag.undecided) {
      newFlags.remove(pair.stem);
    } else {
      newFlags[pair.stem] = flag;
    }

    state = state.copyWith(flags: Map.unmodifiable(newFlags));
    await _saveSession();
  }

  Future<void> _saveSession() async {
    final dir = state.dir;
    if (dir == null) return;
    final session = _buildSession();
    await session.save(dir);
  }

  CullSession _buildSession() {
    return CullSession(flags: Map<String, CullFlag>.from(state.flags));
  }

  void _autoAdvance() {
    // Advance to next undecided after 120 ms.
    Future.delayed(const Duration(milliseconds: 120), () {
      final s = state;
      if (s.pairs.isEmpty) return;

      // Find next undecided after current index
      for (var i = s.index + 1; i < s.pairs.length; i++) {
        final flag = s.flags[s.pairs[i].stem] ?? CullFlag.undecided;
        if (flag == CullFlag.undecided) {
          goto(i);
          return;
        }
      }
      // No more undecided ahead — stay put (do not wrap)
    });
  }

  void _preloadNeighbors(int idx) {
    final pairs = state.pairs;
    if (pairs.isEmpty) return;

    final mode = state.mode;
    for (final offset in [-1, 1]) {
      final ni = idx + offset;
      if (ni < 0 || ni >= pairs.length) continue;
      final key = (stem: pairs[ni].stem, mode: mode);
      // Warm the FutureProvider by reading it (triggers fetch if not cached).
      ref.read(previewProvider(key));
    }
  }
}

final cullControllerProvider =
    NotifierProvider<CullController, CullState>(CullController.new);

// ---------------------------------------------------------------------------
// Derived: per-folder path of the stem relative to directory
// ---------------------------------------------------------------------------

String stemBasename(String fullStemPath) => p.basename(fullStemPath);
