import 'dart:io';
import 'package:file_picker/file_picker.dart';

/// Result of a directory pick operation.
typedef PickResult = ({String? path, String? warning});

/// Service for picking directories via the OS file dialog.
class FilePickService {
  /// Prompts the user to choose a directory.
  ///
  /// Returns a [PickResult] with [path] set on success, or [warning] set if
  /// the picked path is not accessible (e.g., Android SAF URI).
  Future<PickResult> pickDirectory({String? title}) async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: title,
    );

    if (picked == null) return (path: null, warning: null);

    final dir = Directory(picked);
    if (!dir.existsSync()) {
      return (
        path: null,
        warning:
            'The selected folder is not accessible. '
            'Please choose a different location.',
      );
    }

    return (path: picked, warning: null);
  }
}
