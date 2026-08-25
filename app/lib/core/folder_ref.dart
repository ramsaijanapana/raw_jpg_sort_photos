/// Platform-neutral identity for a picked photo folder.
///
/// Local filesystem folders stay [LocalFolder]. Android SAF trees are
/// [SafTree]. This type does not grant access or talk to a picker.
sealed class FolderRef {
  const FolderRef();
}

/// A Task 03 classified local path that `dart:io` can open.
final class LocalFolder extends FolderRef {
  const LocalFolder(this.path);
  final String path;
}

/// An Android document tree. Channels and persistable grants come later.
final class SafTree extends FolderRef {
  const SafTree({
    required this.treeUri,
    required this.documentId,
    required this.displayName,
  });
  final String treeUri;
  final String documentId;
  final String displayName;
}
