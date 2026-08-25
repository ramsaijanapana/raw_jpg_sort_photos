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

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is LocalFolder && path == other.path;

  @override
  int get hashCode => path.hashCode;
}

/// An Android document tree. Channels and persistable grants come later.
///
/// [displayName] is a presentation label and is not part of value identity.
final class SafTree extends FolderRef {
  const SafTree({
    required this.treeUri,
    required this.documentId,
    required this.displayName,
  });
  final String treeUri;
  final String documentId;
  final String displayName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SafTree &&
          treeUri == other.treeUri &&
          documentId == other.documentId;

  @override
  int get hashCode => Object.hash(treeUri, documentId);
}
