import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../folder_ref.dart';
import 'storage_gateway.dart';

/// [StorageGateway] backed by `Directory`, `File`, and `RandomAccessFile`.
///
/// [tryRename] and [deleteSource] are replaceable so the copy-delete move
/// fallback can be exercised without extra packages.
class IoStorageGateway implements StorageGateway {
  IoStorageGateway({
    Future<void> Function(File source, String destPath)? tryRename,
    Future<void> Function(File file)? deleteSource,
  })  : _tryRename = tryRename ??
            ((source, destPath) async {
              await source.rename(destPath);
            }),
        _deleteSource = deleteSource ??
            ((file) async {
              await file.delete();
            });

  final Future<void> Function(File source, String destPath) _tryRename;
  final Future<void> Function(File file) _deleteSource;

  @override
  Future<bool> exists(FolderRef folder) async {
    if (folder is SafTree) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway does not open SAF trees',
      );
    }
    final local = _asLocalFolder(folder);
    return Directory(local.path).exists();
  }

  @override
  Future<List<StorageEntry>> listChildren(
    FolderRef folder, {
    String? childDocumentId,
  }) async {
    final local = _asLocalFolder(folder);
    final dir = Directory(_joinChild(local.path, childDocumentId));
    if (!await dir.exists()) {
      throw StorageException(
        StorageException.notFound,
        'folder not found',
        {'path': dir.path},
      );
    }
    final entries = <StorageEntry>[];
    await for (final entity in dir.list(recursive: false)) {
      final name = p.basename(entity.path);
      if (entity is Directory) {
        entries.add(
          StorageEntry(
            folder: folder,
            name: name,
            mimeType: StorageEntry.directoryMimeType,
            isDirectory: true,
            localPath: entity.path,
          ),
        );
      } else if (entity is File) {
        entries.add(
          StorageEntry(
            folder: folder,
            name: name,
            mimeType: _mimeForName(name),
            isDirectory: false,
            localPath: entity.path,
            size: await entity.length(),
          ),
        );
      }
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Future<StorageEntry?> childByName(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async {
    final local = _asLocalFolder(folder);
    final parent = Directory(_joinChild(local.path, parentDocumentId));
    if (!await parent.exists()) {
      return null;
    }
    final childPath = p.join(parent.path, name);
    final asDir = Directory(childPath);
    if (await asDir.exists()) {
      return StorageEntry(
        folder: folder,
        name: name,
        mimeType: StorageEntry.directoryMimeType,
        isDirectory: true,
        localPath: childPath,
      );
    }
    final asFile = File(childPath);
    if (await asFile.exists()) {
      return StorageEntry(
        folder: folder,
        name: name,
        mimeType: _mimeForName(name),
        isDirectory: false,
        localPath: childPath,
        size: await asFile.length(),
      );
    }
    return null;
  }

  @override
  Future<void> createDirectory(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async {
    _assertFileName(name);
    final local = _asLocalFolder(folder);
    final parent = Directory(_joinChild(local.path, parentDocumentId));
    if (!await parent.exists()) {
      throw StorageException(
        StorageException.notFound,
        'parent folder not found',
        {'path': parent.path},
      );
    }
    final dir = Directory(p.join(parent.path, name));
    if (await dir.exists() || await File(dir.path).exists()) {
      throw StorageException(
        StorageException.alreadyExists,
        'directory already exists',
        {'path': dir.path},
      );
    }
    await dir.create();
  }

  @override
  Future<StorageEntry> createFile(
    FolderRef folder,
    String displayName, {
    required String mimeType,
    String? parentDocumentId,
  }) async {
    _assertFileName(displayName);
    final local = _asLocalFolder(folder);
    final parent = Directory(_joinChild(local.path, parentDocumentId));
    if (!await parent.exists()) {
      throw StorageException(
        StorageException.notFound,
        'parent folder not found',
        {'path': parent.path},
      );
    }
    final path = p.join(parent.path, displayName);
    if (await File(path).exists() || await Directory(path).exists()) {
      throw StorageException(
        StorageException.alreadyExists,
        'file already exists',
        {'path': path},
      );
    }
    await File(path).create();
    return StorageEntry(
      folder: folder,
      name: displayName,
      mimeType: mimeType,
      isDirectory: false,
      localPath: path,
      size: 0,
    );
  }

  @override
  Future<Uint8List> readAll(StorageEntry file) async {
    final path = await _requireExistingFilePath(file);
    return File(path).readAsBytes();
  }

  @override
  Future<Uint8List> readRange(
    StorageEntry file, {
    required int offset,
    required int length,
  }) async {
    if (offset < 0 || length < 0) {
      throw const StorageException(
        StorageException.invalidArg,
        'offset and length must be non-negative',
      );
    }
    final path = await _requireExistingFilePath(file);
    final raf = await File(path).open();
    try {
      final size = await raf.length();
      if (offset > size) {
        throw const StorageException(
          StorageException.invalidArg,
          'offset is past the end of the file',
        );
      }
      if (length == 0 || offset == size) {
        return Uint8List(0);
      }
      final toRead = min(length, size - offset);
      await raf.setPosition(offset);
      return await raf.read(toRead);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<int> byteLength(StorageEntry file) async {
    final path = await _requireExistingFilePath(file);
    return File(path).length();
  }

  @override
  Future<void> writeBytes(StorageEntry file, Uint8List bytes) async {
    final path = await _requireExistingFilePath(file);
    await File(path).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> copyFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
    required bool overwrite,
  }) async {
    final srcPath = await _requireExistingFilePath(source);
    final destPath = _destPath(destFolder, destName, destParentDocumentId);
    await _copyPath(srcPath, destPath, overwrite: overwrite);
  }

  @override
  Future<MoveOutcome> moveFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
  }) async {
    final srcPath = await _requireExistingFilePath(source);
    final destPath = _destPath(destFolder, destName, destParentDocumentId);
    final dest = File(destPath);
    if (await dest.exists() || await Directory(destPath).exists()) {
      throw StorageException(
        StorageException.alreadyExists,
        'destination exists',
        {'path': destPath},
      );
    }
    if (!await dest.parent.exists()) {
      throw StorageException(
        StorageException.notFound,
        'destination folder not found',
        {'path': dest.parent.path},
      );
    }

    if (!await isSameFolder(source.folder, destFolder)) {
      await _copyPath(srcPath, destPath, overwrite: false);
      return MoveOutcome.copiedSourceRemains;
    }

    try {
      await _tryRename(File(srcPath), destPath);
      return MoveOutcome.renamed;
    } on FileSystemException {
      await _copyPath(srcPath, destPath, overwrite: false);
      final destFile = File(destPath);
      final srcFile = File(srcPath);
      if (!await destFile.exists() ||
          await destFile.length() != await srcFile.length()) {
        if (await destFile.exists()) {
          await destFile.delete();
        }
        throw StorageException(
          StorageException.ioFailure,
          'move copy verification failed',
          {'path': destPath},
        );
      }
      final raf = await destFile.open();
      await raf.close();
      try {
        await _deleteSource(srcFile);
      } catch (_) {
        if (await srcFile.exists()) {
          throw StorageException(
            StorageException.incompleteMove,
            'destination written but source delete failed',
            {'path': srcPath},
          );
        }
        rethrow;
      }
      return MoveOutcome.copiedAndDeleted;
    }
  }

  @override
  Future<void> deleteEntry(StorageEntry entry) async {
    if (entry.folder is SafTree) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway does not open SAF trees',
      );
    }
    final path = entry.localPath;
    if (path == null || path.isEmpty) {
      throw const StorageException(
        StorageException.invalidArg,
        'local entry missing localPath',
      );
    }
    _assertSafePath(path);
    if (entry.isDirectory) {
      final dir = Directory(path);
      if (!await dir.exists()) {
        throw StorageException(
          StorageException.notFound,
          'directory not found',
          {'path': path},
        );
      }
      await dir.delete();
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      throw StorageException(
        StorageException.notFound,
        'file not found',
        {'path': path},
      );
    }
    await file.delete();
  }

  @override
  Future<bool> isSameFolder(FolderRef a, FolderRef b) async {
    if (a is LocalFolder && b is LocalFolder) {
      _assertSafePath(a.path);
      _assertSafePath(b.path);
      return _canonicalLocalPath(a.path) == _canonicalLocalPath(b.path);
    }
    if (a is SafTree && b is SafTree) {
      return _normalizeTreeUri(a.treeUri) == _normalizeTreeUri(b.treeUri);
    }
    return false;
  }

  @override
  Future<String> materializeToCache(StorageEntry file) async {
    final bytes = await readAll(file);
    final cache = File(
      p.join(
        Directory.systemTemp.path,
        'ps_mat_${DateTime.now().microsecondsSinceEpoch}_${file.name}',
      ),
    );
    await cache.writeAsBytes(bytes, flush: true);
    return cache.path;
  }

  @override
  Future<void> deleteCache(String cachePath) async {
    _assertSafePath(cachePath);
    final file = File(cachePath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> _copyPath(
    String srcPath,
    String destPath, {
    required bool overwrite,
  }) async {
    final dest = File(destPath);
    final destExisted = await dest.exists();
    if (destExisted && !overwrite) {
      throw StorageException(
        StorageException.alreadyExists,
        'destination exists',
        {'path': destPath},
      );
    }
    if (await Directory(destPath).exists()) {
      throw StorageException(
        StorageException.alreadyExists,
        'destination is a directory',
        {'path': destPath},
      );
    }
    if (!await dest.parent.exists()) {
      throw StorageException(
        StorageException.notFound,
        'destination folder not found',
        {'path': dest.parent.path},
      );
    }
    try {
      final copied = await File(srcPath).copy(destPath);
      if (await copied.length() != await File(srcPath).length()) {
        if (!destExisted && await copied.exists()) {
          await copied.delete();
        }
        throw StorageException(
          StorageException.ioFailure,
          'copy verification failed',
          {'path': destPath},
        );
      }
    } on StorageException {
      rethrow;
    } on FileSystemException catch (e) {
      if (!destExisted && await dest.exists()) {
        await dest.delete();
      }
      throw StorageException(
        StorageException.ioFailure,
        e.message,
        {'path': e.path ?? destPath},
      );
    }
  }

  Future<String> _requireExistingFilePath(StorageEntry entry) async {
    if (entry.isDirectory) {
      throw const StorageException(
        StorageException.invalidArg,
        'expected a file',
      );
    }
    if (entry.folder is SafTree) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway does not open SAF trees',
      );
    }
    if (entry.folder is! LocalFolder) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway accepts LocalFolder only',
      );
    }
    final path = entry.localPath;
    if (path == null || path.isEmpty) {
      throw const StorageException(
        StorageException.invalidArg,
        'local entry missing localPath',
      );
    }
    _assertSafePath(path);
    if (!await File(path).exists()) {
      throw StorageException(
        StorageException.notFound,
        'file not found',
        {'path': path},
      );
    }
    return path;
  }

  String _destPath(
    FolderRef destFolder,
    String destName,
    String? destParentDocumentId,
  ) {
    _assertFileName(destName);
    final local = _asLocalFolder(destFolder);
    return p.join(_joinChild(local.path, destParentDocumentId), destName);
  }

  LocalFolder _asLocalFolder(FolderRef folder) {
    if (folder is SafTree) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway does not open SAF trees',
      );
    }
    if (folder is! LocalFolder) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway accepts LocalFolder only',
      );
    }
    _assertSafePath(folder.path);
    return folder;
  }

  String _joinChild(String folderPath, String? documentId) {
    if (documentId == null || documentId.isEmpty) {
      return folderPath;
    }
    if (documentId.contains('\x00') || documentId.contains('://')) {
      throw const StorageException(
        StorageException.invalidArg,
        'invalid document id',
      );
    }
    for (final part in p.split(documentId)) {
      if (part.isEmpty || part == '.' || part == '..' || p.isAbsolute(part)) {
        throw const StorageException(
          StorageException.invalidArg,
          'invalid document id',
        );
      }
    }
    return p.normalize(p.join(folderPath, documentId));
  }

  void _assertFileName(String name) {
    if (name.isEmpty ||
        name.contains('\x00') ||
        name.contains('/') ||
        name.contains('\\') ||
        name == '.' ||
        name == '..') {
      throw const StorageException(
        StorageException.invalidArg,
        'invalid file name',
      );
    }
  }

  void _assertSafePath(String path) {
    if (path.isEmpty || path.contains('\x00')) {
      throw const StorageException(
        StorageException.invalidArg,
        'invalid path',
      );
    }
    final schemeEnd = path.indexOf(':');
    if (schemeEnd > 1) {
      final scheme = path.substring(0, schemeEnd).toLowerCase();
      if (scheme == 'content' ||
          scheme == 'http' ||
          scheme == 'https' ||
          scheme == 'ftp' ||
          scheme == 'smb') {
        throw const StorageException(
          StorageException.invalidArg,
          'refused non-local path',
        );
      }
    }
  }

  String _canonicalLocalPath(String path) {
    final dir = Directory(path);
    try {
      return dir.resolveSymbolicLinksSync();
    } on FileSystemException {
      return p.normalize(dir.absolute.path);
    }
  }

  String _normalizeTreeUri(String treeUri) {
    final uri = Uri.parse(treeUri);
    final scheme = uri.scheme.toLowerCase();
    final authority = uri.authority.toLowerCase();
    if (authority.isEmpty) {
      return '$scheme:${uri.path}';
    }
    return '$scheme://$authority${uri.path}';
  }

  String _mimeForName(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.json':
        return 'application/json';
      case '.dng':
        return 'image/x-adobe-dng';
      default:
        return 'application/octet-stream';
    }
  }
}
