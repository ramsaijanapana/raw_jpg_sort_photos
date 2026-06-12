import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cull_session.dart';
import '../core/exif_reader.dart';
import '../core/exporter.dart';
import '../core/models.dart';
import '../core/raw_preview/raw_preview_extractor.dart';
import '../core/scanner.dart';
import '../services/prefs_service.dart';

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

  int get decidedCount => keptCount + skipCount;
}

// ---------------------------------------------------------------------------
// LRU cache helper (byte-budget)
// ---------------------------------------------------------------------------

/// Internal wrapper so a cached `null` (= "no preview available") is a
/// distinct, remembered value rather than an absent key.
class LruEntry<V> {
  const LruEntry(this.value);
  final V value;
}

/// A least-recently-used cache bounded by a total byte budget.
///
/// [sizeOf] reports the byte cost of a stored value; on every [put] the cache
/// evicts the oldest entries while the running total exceeds [maxBytes].
/// Storing a value whose own size exceeds [maxBytes] is tolerated: it is kept
/// (so a subsequent [get] hits) but everything else is evicted.
class LruCache<K, V> {
  LruCache(this.maxBytes, this.sizeOf);

  final int maxBytes;
  final int Function(V value) sizeOf;

  final LinkedHashMap<K, LruEntry<V>> _map = LinkedHashMap();
  final Map<K, int> _sizes = {};
  int _totalBytes = 0;

  bool containsKey(K key) => _map.containsKey(key);

  /// Returns the cached entry for [key], or null if absent. Note that a present
  /// entry may itself wrap a `null` value; check [containsKey] to distinguish.
  LruEntry<V>? get(K key) {
    final entry = _map.remove(key);
    if (entry == null) return null;
    // Re-insert to mark most-recently-used.
    _map[key] = entry;
    return entry;
  }

  void put(K key, V value) {
    // Remove any existing entry (and reclaim its bytes) first.
    if (_map.containsKey(key)) {
      _map.remove(key);
      _totalBytes -= _sizes.remove(key) ?? 0;
    }

    final size = sizeOf(value);
    _map[key] = LruEntry<V>(value);
    _sizes[key] = size;
    _totalBytes += size;

    _evictToBudget(protect: key);
  }

  void _evictToBudget({required K protect}) {
    while (_totalBytes > maxBytes && _map.length > 1) {
      final oldest = _map.keys.first;
      // Never evict the entry we just inserted, even if it alone is oversized.
      if (oldest == protect) {
        // Inserted item is the oldest only when it is the sole/over-budget
        // entry; nothing else to evict.
        if (_map.length == 1) break;
        // Move on to the next-oldest by removing and re-adding protect last.
        final entry = _map.remove(oldest)!;
        _map[oldest] = entry;
        continue;
      }
      _map.remove(oldest);
      _totalBytes -= _sizes.remove(oldest) ?? 0;
    }
  }

  int get totalBytes => _totalBytes;
  int get length => _map.length;
}

/// Byte cost of a possibly-null preview entry. A cached `null` (no preview)
/// still occupies a small constant so the budget arithmetic stays sane.
int _previewSizeOf(Uint8List? bytes) => bytes?.lengthInBytes ?? 16;

// ---------------------------------------------------------------------------
// Preview / thumbnail caches (module-level singletons via providers)
// ---------------------------------------------------------------------------

typedef PreviewKey = ({String stem, String mode});

/// Holds the full-resolution preview LRU keyed by (stem, mode).
class PreviewCache {
  final lru = LruCache<PreviewKey, Uint8List?>(32 * 1024 * 1024, _previewSizeOf);
}

/// Holds the filmstrip thumbnail LRU keyed by stem.
class ThumbnailCache {
  final lru = LruCache<String, Uint8List?>(64 * 1024 * 1024, _previewSizeOf);
}

final previewCacheProvider = Provider<PreviewCache>((_) => PreviewCache());
final thumbnailCacheProvider = Provider<ThumbnailCache>((_) => ThumbnailCache());

// ---------------------------------------------------------------------------
// Preview FutureProvider.family (autoDispose — the LRU is the only retention)
// ---------------------------------------------------------------------------

final previewProvider =
    FutureProvider.autoDispose.family<Uint8List?, PreviewKey>(
  (ref, key) async {
    final cache = ref.read(previewCacheProvider);
    if (cache.lru.containsKey(key)) {
      return cache.lru.get(key)!.value;
    }

    final pair = _lookupPair(ref, key.stem);
    if (pair == null) return null;

    Uint8List? bytes;
    if (key.mode == 'jpg' && pair.jpg != null) {
      bytes = await pair.jpg!.readAsBytes();
    } else {
      bytes = await extractPreview(pair.raw);
    }

    cache.lru.put(key, bytes);
    return bytes;
  },
);

// ---------------------------------------------------------------------------
// Thumbnail FutureProvider.family (autoDispose + own LRU)
// ---------------------------------------------------------------------------

final thumbnailProvider =
    FutureProvider.autoDispose.family<Uint8List?, String>(
  (ref, stem) async {
    final cache = ref.read(thumbnailCacheProvider);
    if (cache.lru.containsKey(stem)) {
      return cache.lru.get(stem)!.value;
    }

    final pair = _lookupPair(ref, stem);
    if (pair == null) return null;

    Uint8List? bytes;
    if (pair.jpg != null) {
      bytes = await pair.jpg!.readAsBytes();
    } else {
      bytes = await extractPreview(pair.raw);
    }

    cache.lru.put(stem, bytes);
    return bytes;
  },
);

// ---------------------------------------------------------------------------
// EXIF FutureProvider.family (autoDispose, runs in isolate)
// ---------------------------------------------------------------------------

/// Provides [ExifSummary?] for a given photo stem.
/// Reads the JPG bytes if present, else the first 512 KB of the RAW file.
/// Parsing runs in a separate isolate so the UI thread stays responsive.
final exifProvider =
    FutureProvider.autoDispose.family<ExifSummary?, String>(
  (ref, stem) async {
    final pair = _lookupPair(ref, stem);
    if (pair == null) return null;

    Uint8List bytes;
    if (pair.jpg != null) {
      bytes = await pair.jpg!.readAsBytes();
    } else {
      // Read only first 512 KB for EXIF header parsing.
      final raf = await pair.raw.open();
      try {
        final length = (await pair.raw.length()).clamp(0, 512 * 1024);
        bytes = await raf.read(length);
      } finally {
        await raf.close();
      }
    }

    return Isolate.run(() => readExifSummary(bytes));
  },
);

/// Null-safe lookup of the current pair by stem. Returns null (rather than
/// throwing) when the stem is no longer present — e.g. during a folder switch.
PhotoPair? _lookupPair(Ref ref, String stem) {
  final pairs = ref.read(cullControllerProvider).pairs;
  for (final p in pairs) {
    if (p.stem == stem) return p;
  }
  return null;
}

// ---------------------------------------------------------------------------
// CullController Notifier
// ---------------------------------------------------------------------------

class CullController extends Notifier<CullState> {
  Timer? _advanceTimer;
  int _openGeneration = 0;

  /// Undo stack: each entry records the stem, previous flag, and index at the
  /// time of the change. Capped at 50 entries.
  final List<({String stem, CullFlag prev, int index})> _undoStack = [];

  @override
  CullState build() {
    ref.onDispose(() => _advanceTimer?.cancel());
    return const CullState();
  }

  Future<void> openFolder(String path) async {
    _advanceTimer?.cancel();
    final gen = ++_openGeneration;

    _undoStack.clear();
    state = state.copyWith(loading: true, error: null);

    try {
      final dir = Directory(path);
      final pairs = await scanPairs(dir);
      if (gen != _openGeneration) return;
      pairs.sort((a, b) => a.stem.compareTo(b.stem));
      final session = await CullSession.load(dir);
      if (gen != _openGeneration) return;

      state = state.copyWith(
        dir: dir,
        pairs: pairs,
        flags: Map.unmodifiable(Map<String, CullFlag>.from(session.flags)),
        index: 0,
        loading: false,
        error: null,
      );

      // Persist the folder path for 'Resume' feature.
      try {
        await ref.read(prefsServiceProvider).setLastCullDir(path);
      } catch (_) {
        // Prefs failure is non-fatal.
      }

      _preloadNeighbors(0);
    } catch (e) {
      if (gen != _openGeneration) return;
      state = state.copyWith(
        loading: false,
        error: 'Failed to open folder: $e',
      );
    }
  }

  /// Undo the last flag change: restores the previous flag and navigates
  /// back to the affected photo. No-op when the stack is empty.
  Future<void> undo() async {
    if (_undoStack.isEmpty) return;
    final entry = _undoStack.removeLast();

    final newFlags = Map<String, CullFlag>.from(state.flags);
    if (entry.prev == CullFlag.undecided) {
      newFlags.remove(entry.stem);
    } else {
      newFlags[entry.stem] = entry.prev;
    }

    state = state.copyWith(
      flags: Map.unmodifiable(newFlags),
      index: entry.index,
    );
    await _saveSession();
  }

  void goto(int index) {
    _advanceTimer?.cancel();
    if (state.pairs.isEmpty) return;
    final clamped = index.clamp(0, state.pairs.length - 1);
    state = state.copyWith(index: clamped);
    _preloadNeighbors(clamped);
  }

  void nav(int delta) => goto(state.index + delta);

  Future<void> keep() async {
    _advanceTimer?.cancel();
    await _setFlag(CullFlag.keep);
    _autoAdvance();
  }

  Future<void> skip() async {
    _advanceTimer?.cancel();
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

    // Push undo entry BEFORE mutating.
    final prev = state.flags[pair.stem] ?? CullFlag.undecided;
    _undoStack.add((stem: pair.stem, prev: prev, index: state.index));
    if (_undoStack.length > 50) _undoStack.removeAt(0);

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
    return CullSession(state.flags);
  }

  void _autoAdvance() {
    // Advance to next undecided after 120 ms. Any earlier scheduled timer was
    // cancelled by the caller, so only one advance fires per burst of input.
    _advanceTimer?.cancel();
    _advanceTimer = Timer(const Duration(milliseconds: 120), () {
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
