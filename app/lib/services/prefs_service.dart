import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_path_classifier.dart';

const _kLastCullDir = 'lastCullDir';
const _kLastSortInput = 'lastSortInput';
const _kShowExif = 'showExif';

/// Thin SharedPreferences wrapper that stores only two local path strings.
class PrefsService {
  PrefsService(this._prefs);

  final SharedPreferences _prefs;

  String? get lastCullDir => _prefs.getString(_kLastCullDir);
  String? get lastSortInput => _prefs.getString(_kLastSortInput);

  Future<void> setLastCullDir(String path) =>
      _prefs.setString(_kLastCullDir, path);

  Future<void> setLastSortInput(String path) =>
      _prefs.setString(_kLastSortInput, path);

  Future<void> clearLastCullDir() => _prefs.remove(_kLastCullDir);

  Future<void> clearLastSortInput() => _prefs.remove(_kLastSortInput);

  bool get showExif => _prefs.getBool(_kShowExif) ?? true;

  Future<void> setShowExif(bool value) =>
      _prefs.setBool(_kShowExif, value);

  /// Local filesystem lastCullDir only. `content://` is never Directory-opened.
  String? get lastCullDirIfExists => _localIfExists(lastCullDir);

  /// Local filesystem lastSortInput only. `content://` is never Directory-opened.
  String? get lastSortInputIfExists => _localIfExists(lastSortInput);

  String? _localIfExists(String? stored) {
    if (stored == null) return null;
    final local = classifyLocalDirectoryPath(stored);
    if (local == null) return null;
    return Directory(local).existsSync() ? local : null;
  }
}

/// Provider for [PrefsService]. Must be overridden in [ProviderScope] after
/// [SharedPreferences.getInstance()] is awaited in main().
final prefsServiceProvider = Provider<PrefsService>((ref) {
  throw UnimplementedError(
    'prefsServiceProvider must be overridden with an initialized instance',
  );
});
