import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'local_path_classifier.dart';

/// Result of a directory pick operation.
typedef DirectoryPickResult = ({String? path, String? warning});

/// Back-compat alias used by existing call sites.
typedef PickResult = DirectoryPickResult;

/// Shown when a picked location cannot be used as a local `dart:io` directory.
const directoryAccessWarning =
    'The selected folder is not accessible. '
    'Please choose a different location.';

const DirectoryPickResult _inaccessible = (
  path: null,
  warning: directoryAccessWarning,
);

/// Resolves a picker string for input, output, review, and export.
///
/// Cancelled picks return a null path and null warning. Rejected or
/// unlistable locations return [directoryAccessWarning] and leave callers
/// to keep their existing state.
Future<DirectoryPickResult> interpretPickedDirectory(String? picked) async {
  if (picked == null) return (path: null, warning: null);

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

  return (path: localPath, warning: null);
}

/// Service for picking directories via the OS file dialog.
class FilePickService {
  /// Prompts the user to choose a directory.
  ///
  /// Returns a [DirectoryPickResult] with [DirectoryPickResult.path] set on
  /// success, or [DirectoryPickResult.warning] set if the picked path is not
  /// a usable local folder (e.g. an Android SAF `content://` URI, a remote
  /// URL, or a folder that cannot be listed). Windows drive-letter and
  /// `file://` locations are classified before any filesystem trial.
  Future<DirectoryPickResult> pickDirectory({String? title}) async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: title,
    );
    return interpretPickedDirectory(picked);
  }
}

/// Provider exposing the shared [FilePickService] instance.
final filePickServiceProvider = Provider<FilePickService>(
  (ref) => FilePickService(),
);
