import 'dart:typed_data';

import '../folder_ref.dart';

/// How a [StorageGateway.moveFile] completed.
///
/// An incomplete source delete must throw rather than return [copiedAndDeleted]
/// or [renamed].
enum MoveOutcome {
  renamed,
  copiedAndDeleted,
  copiedSourceRemains,
}

/// Explicit storage failure. Codes match the accepted SAF/local design.
class StorageException implements Exception {
  const StorageException(this.code, this.message, [this.details]);

  static const alreadyExists = 'already_exists';
  static const incompleteMove = 'incomplete_move';
  static const invalidArg = 'invalid_arg';
  static const ioFailure = 'io_failure';
  static const notFound = 'not_found';
  static const unsupported = 'unsupported';

  final String code;
  final String message;
  final Map<String, Object?>? details;

  @override
  String toString() => 'StorageException($code, $message)';
}

/// A folder or file identity that is not a dart:io File.
///
/// [localPath] is set only for local entries. [documentId] is set only when
/// the backing store has a stable document id (SAF). Local entries leave it
/// null and use [localPath].
class StorageEntry {
  const StorageEntry({
    required this.folder,
    required this.name,
    required this.mimeType,
    required this.isDirectory,
    this.documentId,
    this.localPath,
    this.size,
  });

  static const directoryMimeType = 'vnd.android.document/directory';

  final FolderRef folder;
  final String name;
  final String? documentId;
  final String? localPath;
  final String mimeType;
  final int? size;
  final bool isDirectory;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StorageEntry &&
          folder == other.folder &&
          name == other.name &&
          documentId == other.documentId &&
          localPath == other.localPath &&
          mimeType == other.mimeType &&
          size == other.size &&
          isDirectory == other.isDirectory;

  @override
  int get hashCode => Object.hash(
        folder,
        name,
        documentId,
        localPath,
        mimeType,
        size,
        isDirectory,
      );
}

/// Platform-neutral folder and file operations.
abstract class StorageGateway {
  Future<bool> exists(FolderRef folder);

  Future<List<StorageEntry>> listChildren(
    FolderRef folder, {
    String? childDocumentId,
  });

  Future<StorageEntry?> childByName(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  });

  Future<void> createDirectory(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  });

  Future<StorageEntry> createFile(
    FolderRef folder,
    String displayName, {
    required String mimeType,
    String? parentDocumentId,
  });

  Future<Uint8List> readAll(StorageEntry file);

  Future<Uint8List> readRange(
    StorageEntry file, {
    required int offset,
    required int length,
  });

  Future<int> byteLength(StorageEntry file);

  Future<void> writeBytes(StorageEntry file, Uint8List bytes);

  Future<void> copyFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
    required bool overwrite,
  });

  Future<MoveOutcome> moveFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
  });

  Future<void> deleteEntry(StorageEntry entry);

  Future<bool> isSameFolder(FolderRef a, FolderRef b);

  Future<String> materializeToCache(StorageEntry file);

  Future<void> deleteCache(String cachePath);
}
