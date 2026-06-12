import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Result of a directory pick operation.
typedef PickResult = ({String? path, String? warning});

/// Service for picking directories via the OS file dialog.
class FilePickService {
  /// Prompts the user to choose a directory.
  ///
  /// Returns a [PickResult] with [path] set on success, or [warning] set if
  /// the picked path is not accessible (e.g., an Android SAF `content://` URI
  /// or a folder that cannot be listed).
  Future<PickResult> pickDirectory({String? title}) async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: title,
    );

    if (picked == null) return (path: null, warning: null);

    const inaccessible = (
      path: null,
      warning: 'The selected folder is not accessible. '
          'Please choose a different location.',
    );

    // Reject URIs that carry a scheme (e.g. content://, file://). These are
    // not plain filesystem paths the rest of the app can operate on.
    final uri = Uri.tryParse(picked);
    if (uri != null && uri.hasScheme) {
      return inaccessible;
    }

    final dir = Directory(picked);
    if (!dir.existsSync()) {
      return inaccessible;
    }

    // Trial read: confirm we can actually enumerate the directory.
    try {
      await dir.list().take(1).toList();
    } catch (_) {
      return inaccessible;
    }

    return (path: picked, warning: null);
  }
}

/// Provider exposing the shared [FilePickService] instance.
final filePickServiceProvider = Provider<FilePickService>(
  (ref) => FilePickService(),
);
