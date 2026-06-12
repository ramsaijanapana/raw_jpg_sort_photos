import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'models.dart';

/// File name used to persist cull session data. Backward-compatible with
/// the Python app's cull_session.json format.
const String cullSessionFileName = 'cull_session.json';

/// Manages per-folder cull decisions (keep/skip/undecided) for a set of
/// photo stems.
///
/// Persisted as JSON: `{"stem": "keep"|"skip"}`. Undecided photos are omitted
/// from the file. This matches the Python app's format exactly.
class CullSession {
  final Map<String, CullFlag> _flags;

  /// Creates a session, copying [initial] so external mutations of the passed
  /// map do not leak into the session (and vice versa).
  CullSession([Map<String, CullFlag>? initial])
      : _flags = Map<String, CullFlag>.from(initial ?? const {});

  /// Read-only view of the current flags.
  Map<String, CullFlag> get flags => UnmodifiableMapView(_flags);

  /// Loads a [CullSession] from [folder]/cull_session.json.
  ///
  /// Returns an empty session if the file is missing or contains invalid JSON.
  /// Never throws.
  static Future<CullSession> load(Directory folder) async {
    final file = File(p.join(folder.path, cullSessionFileName));
    try {
      if (!await file.exists()) {
        return CullSession();
      }
      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return CullSession();

      final flags = <String, CullFlag>{};
      for (final entry in decoded.entries) {
        final stem = entry.key as String;
        final value = entry.value;
        if (value == 'keep') {
          flags[stem] = CullFlag.keep;
        } else if (value == 'skip') {
          flags[stem] = CullFlag.skip;
        }
        // Unknown values are silently ignored (treated as undecided)
      }
      return CullSession(flags);
    } catch (_) {
      // Corrupt file or any other error => return empty session
      return CullSession();
    }
  }

  /// Saves the session to [folder]/cull_session.json.
  ///
  /// Only keep/skip flags are written; undecided entries are omitted.
  /// Failures are silently ignored.
  Future<void> save(Directory folder) async {
    try {
      final data = <String, String>{};
      for (final entry in _flags.entries) {
        if (entry.value == CullFlag.keep) {
          data[entry.key] = 'keep';
        } else if (entry.value == CullFlag.skip) {
          data[entry.key] = 'skip';
        }
        // undecided => omit
      }
      final file = File(p.join(folder.path, cullSessionFileName));
      await file.writeAsString(jsonEncode(data));
    } catch (_) {
      // Ignore write errors silently
    }
  }

  /// Returns the flag for [stem], defaulting to [CullFlag.undecided].
  CullFlag flagFor(String stem) => _flags[stem] ?? CullFlag.undecided;

  /// Sets the flag for [stem].
  void setFlag(String stem, CullFlag flag) {
    if (flag == CullFlag.undecided) {
      _flags.remove(stem);
    } else {
      _flags[stem] = flag;
    }
  }

  @override
  String toString() => 'CullSession(${_flags.length} flags)';
}
