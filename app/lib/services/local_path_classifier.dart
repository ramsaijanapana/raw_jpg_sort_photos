/// Pure classifier for directory-picker strings.
///
/// Accepts local filesystem locations the rest of the app can use with
/// `dart:io`. Rejects non-file URI schemes (including Android `content://`)
/// and malformed or NUL-containing values. Never treats a single-letter
/// Windows drive prefix as a URI scheme.
///
/// Does not request storage permissions and does not invent access to
/// content URIs.
String? classifyLocalDirectoryPath(String raw) {
  if (raw.isEmpty || raw.contains('\u0000')) return null;

  if (_isWindowsDrivePath(raw) || _isUncPath(raw)) return raw;

  final scheme = _leadingUriScheme(raw);
  if (scheme == null) return raw;
  if (scheme == 'file') return _fileUriToLocalPath(raw);
  return null;
}

bool _isWindowsDrivePath(String raw) {
  if (raw.length < 3) return false;
  final drive = raw.codeUnitAt(0);
  final isLetter =
      (drive >= 65 && drive <= 90) || (drive >= 97 && drive <= 122);
  if (!isLetter) return false;
  if (raw.codeUnitAt(1) != 0x3A) return false; // ':'
  final sep = raw.codeUnitAt(2);
  return sep == 0x5C || sep == 0x2F; // '\' or '/'
}

bool _isUncPath(String raw) {
  return raw.length >= 2 &&
      raw.codeUnitAt(0) == 0x5C &&
      raw.codeUnitAt(1) == 0x5C;
}

final _schemePrefix = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*):');

String? _leadingUriScheme(String raw) {
  return _schemePrefix.firstMatch(raw)?.group(1)?.toLowerCase();
}

String? _fileUriToLocalPath(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.isScheme('file')) return null;
  try {
    final path = uri.toFilePath();
    if (path.isEmpty || path.contains('\u0000')) return null;
    return path;
  } on UnsupportedError {
    return null;
  }
}
