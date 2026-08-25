import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../services/local_path_classifier.dart';
import '../folder_ref.dart';
import 'storage_gateway.dart';

/// [StorageGateway] backed by `Directory`, `File`, and `RandomAccessFile`.
///
/// [tryRename], [deleteSource], [copyTo], [verifyCopied], and [replaceFile]
/// are replaceable so copy-delete and transactional overwrite can be
/// exercised without extra packages. Production defaults stay real.
class IoStorageGateway implements StorageGateway {
  IoStorageGateway({
    Future<void> Function(File source, String destPath)? tryRename,
    Future<void> Function(File file)? deleteSource,
    Future<File> Function(File source, String destPath)? copyTo,
    Future<void> Function(File copied, File source)? verifyCopied,
    Future<void> Function(File temp, String destPath)? replaceFile,
    Future<void> Function()? injectIo,
    Directory? cacheDirectory,
  })  : _tryRename = tryRename ??
            ((source, destPath) async {
              await source.rename(destPath);
            }),
        _deleteSource = deleteSource ??
            ((file) async {
              await file.delete();
            }),
        _copyTo = copyTo ?? ((source, destPath) => source.copy(destPath)),
        _verifyCopied = verifyCopied,
        _replaceFile = replaceFile,
        _injectIo = injectIo,
        _cacheDirectory = cacheDirectory;

  final Future<void> Function(File source, String destPath) _tryRename;
  final Future<void> Function(File file) _deleteSource;
  final Future<File> Function(File source, String destPath) _copyTo;
  final Future<void> Function(File copied, File source)? _verifyCopied;
  final Future<void> Function(File temp, String destPath)? _replaceFile;
  final Future<void> Function()? _injectIo;
  final Directory? _cacheDirectory;

  final Set<String> _ownedCachePaths = <String>{};
  final Set<String> _retiredCachePaths = <String>{};
  int _seq = 0;

  @override
  Future<bool> exists(FolderRef folder) async {
    if (folder is SafTree) {
      throw const StorageException(
        StorageException.unsupported,
        'IoStorageGateway does not open SAF trees',
      );
    }
    final local = _asLocalFolder(folder);
    return _guardIo(() => Directory(local.path).exists());
  }

  @override
  Future<List<StorageEntry>> listChildren(
    FolderRef folder, {
    String? childDocumentId,
  }) async {
    final local = _asLocalFolder(folder);
    final dirPath = _joinChild(local.path, childDocumentId);
    return _guardIo(() async {
      final dir = Directory(dirPath);
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
    });
  }

  @override
  Future<StorageEntry?> childByName(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async {
    final local = _asLocalFolder(folder);
    final parentPath = _joinChild(local.path, parentDocumentId);
    return _guardIo(() async {
      final parent = Directory(parentPath);
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
    });
  }

  @override
  Future<void> createDirectory(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async {
    _assertFileName(name);
    final local = _asLocalFolder(folder);
    final parentPath = _joinChild(local.path, parentDocumentId);
    await _guardIo(() async {
      final parent = Directory(parentPath);
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
    });
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
    final parentPath = _joinChild(local.path, parentDocumentId);
    return _guardIo(() async {
      final parent = Directory(parentPath);
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
    });
  }

  @override
  Future<Uint8List> readAll(StorageEntry file) async {
    return _guardIo(() async {
      final path = await _requireExistingFilePath(file);
      return File(path).readAsBytes();
    });
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
    return _guardIo(() async {
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
    });
  }

  @override
  Future<int> byteLength(StorageEntry file) async {
    return _guardIo(() async {
      final path = await _requireExistingFilePath(file);
      return File(path).length();
    });
  }

  @override
  Future<void> writeBytes(StorageEntry file, Uint8List bytes) async {
    await _guardIo(() async {
      final path = await _requireExistingFilePath(file);
      await File(path).writeAsBytes(bytes, flush: true);
    });
  }

  @override
  Future<void> copyFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
    required bool overwrite,
  }) async {
    final destPath = _destPath(destFolder, destName, destParentDocumentId);
    await _guardIo(() async {
      final srcPath = await _requireExistingFilePath(source);
      await _copyPath(srcPath, destPath, overwrite: overwrite);
    });
  }

  @override
  Future<MoveOutcome> moveFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
  }) async {
    final destPath = _destPath(destFolder, destName, destParentDocumentId);
    return _guardIo(() async {
      final srcPath = await _requireExistingFilePath(source);
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
    });
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
    await _guardIo(() async {
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
    });
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
    if (file.isDirectory) {
      throw const StorageException(
        StorageException.invalidArg,
        'expected a file',
      );
    }
    _assertFileName(file.name);
    return _guardIo(() async {
      final srcPath = await _requireExistingFilePath(file);
      final cacheDir = _cacheDirectory ?? Directory.systemTemp;
      final cachePath = p.join(cacheDir.path, 'ps_mat_${_uniqueToken()}');
      final cache = File(cachePath);
      var issued = false;
      try {
        await _copyTo(File(srcPath), cachePath);
        await _verifyCopy(cache, File(srcPath));
        _ownedCachePaths.add(cachePath);
        _retiredCachePaths.remove(cachePath);
        issued = true;
        return cachePath;
      } finally {
        if (!issued) {
          await _deleteQuietly(cache);
        }
      }
    });
  }

  @override
  Future<void> deleteCache(String cachePath) async {
    _assertSafePath(cachePath);
    if (_retiredCachePaths.contains(cachePath)) {
      return;
    }
    if (!_ownedCachePaths.contains(cachePath)) {
      throw const StorageException(
        StorageException.invalidArg,
        'cache path was not issued by this gateway',
      );
    }
    await _guardIo(() async {
      final file = File(cachePath);
      if (await file.exists()) {
        await file.delete();
      }
      _ownedCachePaths.remove(cachePath);
      _retiredCachePaths.add(cachePath);
    });
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

    final temp = File(p.join(dest.parent.path, 'ps_copy_${_uniqueToken()}'));
    try {
      await _copyTo(File(srcPath), temp.path);
      await _verifyCopy(temp, File(srcPath));
      await _replaceDestination(temp, destPath);
    } on StorageException {
      await _deleteQuietly(temp);
      rethrow;
    } on FileSystemException catch (e) {
      await _deleteQuietly(temp);
      throw _toStorageException(e);
    } catch (e) {
      await _deleteQuietly(temp);
      rethrow;
    }
  }

  Future<void> _verifyCopy(File copied, File source) async {
    if (_verifyCopied != null) {
      await _verifyCopied!(copied, source);
      return;
    }
    if (!await copied.exists() ||
        await copied.length() != await source.length()) {
      throw StorageException(
        StorageException.ioFailure,
        'copy verification failed',
        {'path': copied.path},
      );
    }
    final raf = await copied.open();
    await raf.close();
  }

  Future<void> _replaceDestination(File temp, String destPath) async {
    if (_replaceFile != null) {
      await _replaceFile!(temp, destPath);
      return;
    }
    try {
      await temp.rename(destPath);
      return;
    } on FileSystemException {
      if (!await File(destPath).exists()) {
        rethrow;
      }
    }
    final backup = File(p.join(p.dirname(destPath), 'ps_bak_${_uniqueToken()}'));
    await File(destPath).rename(backup.path);
    try {
      await temp.rename(destPath);
    } catch (e) {
      try {
        await backup.rename(destPath);
      } catch (_) {}
      rethrow;
    }
    await _deleteQuietly(backup);
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
    final classified = classifyLocalDirectoryPath(path);
    if (classified == null || classified != path) {
      throw const StorageException(
        StorageException.invalidArg,
        'refused non-local path',
      );
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

  Future<T> _guardIo<T>(Future<T> Function() action) async {
    try {
      if (_injectIo != null) {
        await _injectIo!();
      }
      return await action();
    } on StorageException {
      rethrow;
    } on FileSystemException catch (e) {
      throw _toStorageException(e);
    }
  }

  StorageException _toStorageException(FileSystemException e) {
    return StorageException(
      _isEnospc(e) ? StorageException.quota : StorageException.ioFailure,
      e.message,
      {'path': e.path},
    );
  }

  bool _isEnospc(FileSystemException e) {
    final code = e.osError?.errorCode;
    if (code == null) return false;
    // POSIX ENOSPC is portable. Windows ERROR_DISK_FULL is 112, but 112 is
    // ENEEDAUTH / EHOSTDOWN on Darwin / Linux.
    if (code == 28) return true;
    return code == 112 && Platform.isWindows;
  }

  String _uniqueToken() {
    _seq += 1;
    return '${DateTime.now().microsecondsSinceEpoch}_$_seq';
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
