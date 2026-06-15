import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  bool get showExif => _prefs.getBool(_kShowExif) ?? true;

  Future<void> setShowExif(bool value) =>
      _prefs.setBool(_kShowExif, value);

  /// Returns lastCullDir only if the directory actually exists on disk.
  String? get lastCullDirIfExists {
    final p = lastCullDir;
    if (p == null) return null;
    return Directory(p).existsSync() ? p : null;
  }

  /// Returns lastSortInput only if the directory actually exists on disk.
  String? get lastSortInputIfExists {
    final p = lastSortInput;
    if (p == null) return null;
    return Directory(p).existsSync() ? p : null;
  }
}

/// Provider for [PrefsService]. Must be overridden in [ProviderScope] after
/// [SharedPreferences.getInstance()] is awaited in main().
final prefsServiceProvider = Provider<PrefsService>((ref) {
  throw UnimplementedError(
    'prefsServiceProvider must be overridden with an initialized instance',
  );
});
