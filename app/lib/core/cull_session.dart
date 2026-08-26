import 'dart:collection';
import 'dart:convert';

import 'folder_ref.dart';
import 'models.dart';
import 'storage/storage_gateway.dart';

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
  static Future<CullSession> load(
    FolderRef folder, {
    required StorageGateway gateway,
  }) async {
    try {
      final entry = await gateway.childByName(folder, cullSessionFileName);
      if (entry == null || entry.isDirectory) {
        return CullSession();
      }
      final text = utf8.decode(await gateway.readAll(entry));
      final decoded = jsonDecode(text);
      if (decoded is! Map) return CullSession();

      final flags = <String, CullFlag>{};
      for (final mapEntry in decoded.entries) {
        final stem = mapEntry.key as String;
        final value = mapEntry.value;
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
  /// Failures are silently ignored when [ignoreErrors] is true (the default).
  /// Does not create a missing folder.
  Future<void> save(
    FolderRef folder, {
    required StorageGateway gateway,
    bool ignoreErrors = true,
  }) async {
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
      var file = await gateway.childByName(folder, cullSessionFileName);
      if (file == null || file.isDirectory) {
        file = await gateway.createFile(
          folder,
          cullSessionFileName,
          mimeType: 'application/json',
        );
      }
      await gateway.writeBytes(file, utf8.encode(jsonEncode(data)));
    } catch (e) {
      if (ignoreErrors) return;
      rethrow;
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
