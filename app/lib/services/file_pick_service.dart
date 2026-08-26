import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/folder_ref.dart';
import '../core/storage/storage_gateway.dart';
import 'local_path_classifier.dart';
import 'saf/saf_channel.dart';

/// Result of a directory pick operation.
///
/// [path] and [warning] keep the Task 03 contract. [folder] is additive:
/// [LocalFolder] on a usable local path, otherwise null. Android SAF is
/// not interpreted here.
typedef DirectoryPickResult = ({
  String? path,
  String? warning,
  FolderRef? folder,
});

/// Back-compat alias used by existing call sites.
typedef PickResult = DirectoryPickResult;

/// Shown when a picked location cannot be used as a local `dart:io` directory.
const directoryAccessWarning =
    'The selected folder is not accessible. '
    'Please choose a different location.';

const DirectoryPickResult _inaccessible = (
  path: null,
  warning: directoryAccessWarning,
  folder: null,
);

const DirectoryPickResult _cancelled = (
  path: null,
  warning: null,
  folder: null,
);

/// Resolves a picker string for input, output, review, and export.
///
/// Cancelled picks return a null path, null warning, and null folder.
/// Rejected or unlistable locations return [directoryAccessWarning] and
/// leave callers to keep their existing state.
Future<DirectoryPickResult> interpretPickedDirectory(String? picked) async {
  if (picked == null) {
    return (path: null, warning: null, folder: null);
  }

  final localPath = classifyLocalDirectoryPath(picked);
  if (localPath == null) return _inaccessible;

  final dir = Directory(localPath);
  if (!dir.existsSync()) {
    return _inaccessible;
  }

  // Trial read: confirm we can actually enumerate the directory.
  try {
    await dir.list().take(1).toList();
  } catch (_) {
    return _inaccessible;
  }

  return (
    path: localPath,
    warning: null,
    folder: LocalFolder(localPath),
  );
}

/// Service for picking directories via the OS file dialog.
class FilePickService {
  FilePickService({
    SafChannel? safChannel,
    bool Function()? isAndroid,
    Future<String?> Function({String? dialogTitle})? pickLocalDirectory,
  })  : _saf = safChannel ?? SafChannel(),
        _isAndroid =
            isAndroid ?? (() => defaultTargetPlatform == TargetPlatform.android),
        _pickLocal = pickLocalDirectory ??
            ({String? dialogTitle}) =>
                FilePicker.getDirectoryPath(dialogTitle: dialogTitle);

  final SafChannel _saf;
  final bool Function() _isAndroid;
  final Future<String?> Function({String? dialogTitle}) _pickLocal;

  /// Safe title for Sort / Review labels. Never a URI or document id.
  static String folderDisplayName(FolderRef folder) {
    if (folder is LocalFolder) {
      return p.basename(folder.path);
    }
    if (folder is SafTree) {
      final name = folder.displayName.trim();
      if (name.isNotEmpty && !name.contains('://')) {
        return name;
      }
      return 'Selected folder';
    }
    return 'Selected folder';
  }

  /// True when [raw] is a `content://…/tree/<id>` reference.
  static bool looksLikeContentTreeUri(String? raw) {
    return _treeDocumentIdFromUri(raw) != null;
  }

  /// Prompts the user to choose a directory.
  ///
  /// Returns a [DirectoryPickResult] with [DirectoryPickResult.path] set on
  /// success, or [DirectoryPickResult.warning] set if the picked path is not
  /// a usable local folder (e.g. an Android SAF `content://` URI, a remote
  /// URL, or a folder that cannot be listed). Windows drive-letter and
  /// `file://` locations are classified before any filesystem trial.
  ///
  /// On Android this calls [SafChannel.pickTree] and idempotent
  /// [SafChannel.takePersistable]. It never invokes FilePicker or treats the
  /// tree URI as a filesystem path.
  Future<DirectoryPickResult> pickDirectory({String? title}) async {
    if (_isAndroid()) {
      return _pickAndroidDirectory(title: title);
    }
    final picked = await _pickLocal(dialogTitle: title);
    return interpretPickedDirectory(picked);
  }

  Future<DirectoryPickResult> _pickAndroidDirectory({String? title}) async {
    try {
      final picked = await _saf.pickTree(title: title);
      if (picked == null) return _cancelled;
      try {
        await _saf.takePersistable(picked.tree.treeUri);
      } on StorageException {
        return _inaccessible;
      }
      return (path: null, warning: null, folder: picked.tree);
    } on StorageException {
      return _inaccessible;
    }
  }

  /// Reconstructs a [FolderRef] from a stored prefs string.
  ///
  /// May clear **only** the provided stale key. Never deletes user content.
  Future<FolderRef?> restorePersistedFolder(
    String? stored, {
    required Future<void> Function() clearStale,
  }) async {
    if (stored == null || stored.isEmpty) return null;

    final local = classifyLocalDirectoryPath(stored);
    if (local != null) {
      return Directory(local).existsSync() ? LocalFolder(local) : null;
    }

    if (stored.contains('\u0000') || !_isContentUri(stored)) {
      await clearStale();
      return null;
    }

    if (!_isAndroid()) {
      await clearStale();
      return null;
    }

    try {
      final persisted = await _saf.hasPersisted(stored);
      if (!persisted) {
        await clearStale();
        return null;
      }
    } on StorageException catch (e) {
      if (e.code == StorageException.permissionDenied ||
          e.code == StorageException.notFound) {
        await clearStale();
        return null;
      }
      return null;
    }

    try {
      final trees = await _saf.persistedTrees();
      final storedNorm = _normalizeTreeUri(stored);
      for (final tree in trees) {
        if (_normalizeTreeUri(tree.treeUri) != storedNorm) continue;
        if (tree.documentId.isEmpty || tree.documentId.contains('\u0000')) {
          await clearStale();
          return null;
        }
        return tree;
      }
    } on StorageException {
      return null;
    } catch (_) {
      return null;
    }

    final documentId = _treeDocumentIdFromUri(stored);
    if (documentId != null) {
      return SafTree(
        treeUri: stored,
        documentId: documentId,
        displayName: '',
      );
    }

    await clearStale();
    return null;
  }
}

bool _isContentUri(String raw) {
  if (raw.contains('\u0000')) return false;
  final uri = Uri.tryParse(raw);
  return uri != null && uri.scheme.toLowerCase() == 'content';
}

String? _treeDocumentIdFromUri(String? raw) {
  if (raw == null || raw.isEmpty || raw.contains('\u0000')) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme.toLowerCase() != 'content') return null;
  final segs = uri.pathSegments;
  if (segs.length < 2 || segs[0] != 'tree') return null;
  final id = segs[1];
  if (id.isEmpty || id.contains('\u0000')) return null;
  return id;
}

/// Copy of `SafStorageGateway._normalizeTreeUri` — do not export that file.
String _normalizeTreeUri(String treeUri) {
  final uri = Uri.parse(treeUri);
  final scheme = uri.scheme.toLowerCase();
  final authority = uri.authority.toLowerCase();
  if (authority.isEmpty) {
    return '$scheme:${uri.path}';
  }
  return '$scheme://$authority${uri.path}';
}

/// Provider exposing the shared [FilePickService] instance.
final filePickServiceProvider = Provider<FilePickService>(
  (ref) => FilePickService(),
);
