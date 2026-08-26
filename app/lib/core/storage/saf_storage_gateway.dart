import 'dart:math';
import 'dart:typed_data';

import '../../services/saf/saf_channel.dart';
import '../folder_ref.dart';
import 'byte_range_reader.dart';
import 'storage_gateway.dart';

/// [StorageGateway] over [SafChannel] for [SafTree] identities.
///
/// Parent ids the engines already pass (`RAW` / `JPG`) are resolved to
/// opaque document ids. Local folders are refused except [isSameFolder]
/// mixed-type compares.
class SafStorageGateway implements StorageGateway {
  SafStorageGateway([SafChannel? channel]) : _channel = channel ?? SafChannel();

  final SafChannel _channel;
  final Set<String> _issuedCachePaths = <String>{};
  final Set<String> _retiredCachePaths = <String>{};
  int _seq = 0;

  @override
  Future<bool> exists(FolderRef folder) async {
    final tree = _requireTree(folder);
    try {
      await _channel.listChildren(
        treeUri: tree.treeUri,
        documentId: tree.documentId,
        folder: tree,
      );
      return true;
    } on StorageException catch (e) {
      if (e.code == StorageException.notFound) return false;
      rethrow;
    }
  }

  @override
  Future<List<StorageEntry>> listChildren(
    FolderRef folder, {
    String? childDocumentId,
  }) async {
    final tree = _requireTree(folder);
    final documentId = await _resolveDocumentId(tree, childDocumentId);
    final entries = await _channel.listChildren(
      treeUri: tree.treeUri,
      documentId: documentId,
      folder: tree,
    );
    entries.sort((a, b) => a.name.compareTo(b.name));
    return entries;
  }

  @override
  Future<StorageEntry?> childByName(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async {
    final tree = _requireTree(folder);
    _assertFileName(name);
    try {
      final parentId = await _resolveDocumentId(tree, parentDocumentId);
      return await _channel.childByName(
        treeUri: tree.treeUri,
        parentDocumentId: parentId,
        name: name,
        folder: tree,
      );
    } on StorageException catch (e) {
      if (e.code == StorageException.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<void> createDirectory(
    FolderRef folder,
    String name, {
    String? parentDocumentId,
  }) async {
    final tree = _requireTree(folder);
    _assertFileName(name);
    final parentId = await _resolveDocumentId(tree, parentDocumentId);
    await _channel.createDirectory(
      treeUri: tree.treeUri,
      parentDocumentId: parentId,
      name: name,
      folder: tree,
    );
  }

  @override
  Future<StorageEntry> createFile(
    FolderRef folder,
    String displayName, {
    required String mimeType,
    String? parentDocumentId,
  }) async {
    final tree = _requireTree(folder);
    _assertFileName(displayName);
    final parentId = await _resolveDocumentId(tree, parentDocumentId);
    return _channel.createFile(
      treeUri: tree.treeUri,
      parentDocumentId: parentId,
      displayName: displayName,
      mimeType: mimeType,
      folder: tree,
    );
  }

  @override
  Future<Uint8List> readAll(StorageEntry file) async {
    final tree = _requireFileTree(file);
    final documentId = _requireDocumentId(file);
    final size = await _channel.byteLength(
      treeUri: tree.treeUri,
      documentId: documentId,
    );
    if (size == 0) return Uint8List(0);
    return _channel.readRange(
      treeUri: tree.treeUri,
      documentId: documentId,
      offset: 0,
      length: size,
    );
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
    final tree = _requireFileTree(file);
    final documentId = _requireDocumentId(file);
    final size = await _channel.byteLength(
      treeUri: tree.treeUri,
      documentId: documentId,
    );
    if (offset > size) {
      throw const StorageException(
        StorageException.invalidArg,
        'offset is past the end of the file',
      );
    }
    if (length == 0 || offset == size) {
      return Uint8List(0);
    }
    return _channel.readRange(
      treeUri: tree.treeUri,
      documentId: documentId,
      offset: offset,
      length: min(length, size - offset),
    );
  }

  @override
  Future<int> byteLength(StorageEntry file) async {
    final tree = _requireFileTree(file);
    return _channel.byteLength(
      treeUri: tree.treeUri,
      documentId: _requireDocumentId(file),
    );
  }

  @override
  Future<void> writeBytes(StorageEntry file, Uint8List bytes) async {
    final tree = _requireFileTree(file);
    await _channel.writeBytes(
      treeUri: tree.treeUri,
      documentId: _requireDocumentId(file),
      bytes: bytes,
    );
  }

  @override
  Future<void> copyFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
    required bool overwrite,
  }) async {
    final srcTree = _requireFileTree(source);
    final destTree = _requireTree(destFolder);
    _assertFileName(destName);
    final destParentId = await _resolveDocumentId(
      destTree,
      destParentDocumentId,
    );
    await _channel.copyTo(
      srcTreeUri: srcTree.treeUri,
      srcDocumentId: _requireDocumentId(source),
      destTreeUri: destTree.treeUri,
      destParentId: destParentId,
      destName: destName,
      overwrite: overwrite,
      opId: _nextOpId(),
      destFolder: destTree,
    );
  }

  @override
  Future<MoveOutcome> moveFile(
    StorageEntry source,
    FolderRef destFolder,
    String destName, {
    String? destParentDocumentId,
  }) async {
    final srcTree = _requireFileTree(source);
    final destTree = _requireTree(destFolder);
    _assertFileName(destName);
    final destParentId = await _resolveDocumentId(
      destTree,
      destParentDocumentId,
    );
    final result = await _channel.move(
      treeUri: srcTree.treeUri,
      documentId: _requireDocumentId(source),
      sourceParentId: null,
      destParentId: destParentId,
      destName: destName,
      folder: destTree,
    );
    return _mapMoveOutcome(
      result.outcome,
      await isSameFolder(source.folder, destFolder),
    );
  }

  @override
  Future<void> deleteEntry(StorageEntry entry) async {
    final tree = _requireTree(entry.folder);
    await _channel.delete(
      treeUri: tree.treeUri,
      documentId: _requireDocumentId(entry),
    );
  }

  @override
  Future<bool> isSameFolder(FolderRef a, FolderRef b) async {
    if (a is SafTree && b is SafTree) {
      return _normalizeTreeUri(a.treeUri) == _normalizeTreeUri(b.treeUri);
    }
    if (a is LocalFolder && b is LocalFolder) {
      throw const StorageException(
        StorageException.unsupported,
        'SafStorageGateway does not compare local folders',
      );
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
    assertSafeCacheFileName(file.name);
    final tree = _requireFileTree(file);
    final result = await _channel.materializeToCache(
      treeUri: tree.treeUri,
      documentId: _requireDocumentId(file),
      opId: _nextOpId(),
    );
    _issuedCachePaths.add(result.cachePath);
    _retiredCachePaths.remove(result.cachePath);
    return result.cachePath;
  }

  @override
  Future<void> deleteCache(String cachePath) async {
    if (cachePath.isEmpty || cachePath.contains('\x00')) {
      throw const StorageException(
        StorageException.invalidArg,
        'invalid cache path',
      );
    }
    if (_retiredCachePaths.contains(cachePath)) {
      return;
    }
    if (!_issuedCachePaths.contains(cachePath)) {
      throw const StorageException(
        StorageException.invalidArg,
        'cache path was not issued by this gateway',
      );
    }
    await _channel.deleteCache(cachePath);
    _issuedCachePaths.remove(cachePath);
    _retiredCachePaths.add(cachePath);
  }

  Future<String> _resolveDocumentId(SafTree folder, String? id) async {
    if (id == null || id.isEmpty) {
      return folder.documentId;
    }
    if (id.contains('\x00')) {
      throw const StorageException(
        StorageException.invalidArg,
        'invalid document id',
      );
    }
    try {
      final child = await _channel.childByName(
        treeUri: folder.treeUri,
        parentDocumentId: folder.documentId,
        name: id,
        folder: folder,
      );
      final childId = child?.documentId;
      if (child != null &&
          child.isDirectory &&
          childId != null &&
          childId.isNotEmpty) {
        return childId;
      }
    } on StorageException catch (e) {
      if (e.code != StorageException.notFound) rethrow;
    }
    return id;
  }

  MoveOutcome _mapMoveOutcome(String? outcome, bool sameTree) {
    switch (outcome) {
      case 'renamed':
        return MoveOutcome.renamed;
      case 'copiedAndDeleted':
        return MoveOutcome.copiedAndDeleted;
      case 'copiedSourceRemains':
        if (sameTree) {
          throw const StorageException(
            StorageException.incompleteMove,
            'same-tree move left the source in place',
          );
        }
        return MoveOutcome.copiedSourceRemains;
      default:
        throw const StorageException(
          StorageException.invalidArg,
          'missing move outcome',
        );
    }
  }

  SafTree _requireTree(FolderRef folder) {
    if (folder is LocalFolder) {
      throw const StorageException(
        StorageException.unsupported,
        'SafStorageGateway does not open local folders',
      );
    }
    if (folder is! SafTree) {
      throw const StorageException(
        StorageException.unsupported,
        'SafStorageGateway accepts SafTree only',
      );
    }
    _assertTreeIdentity(folder);
    return folder;
  }

  SafTree _requireFileTree(StorageEntry file) {
    if (file.isDirectory) {
      throw const StorageException(
        StorageException.invalidArg,
        'expected a file',
      );
    }
    return _requireTree(file.folder);
  }

  String _requireDocumentId(StorageEntry entry) {
    final documentId = entry.documentId;
    if (documentId == null ||
        documentId.isEmpty ||
        documentId.contains('\x00')) {
      throw const StorageException(
        StorageException.invalidArg,
        'SAF entry missing documentId',
      );
    }
    return documentId;
  }

  void _assertTreeIdentity(SafTree tree) {
    if (tree.treeUri.isEmpty ||
        tree.treeUri.contains('\x00') ||
        tree.documentId.isEmpty ||
        tree.documentId.contains('\x00')) {
      throw const StorageException(
        StorageException.invalidArg,
        'invalid SAF tree identity',
      );
    }
    final uri = Uri.parse(tree.treeUri);
    if (uri.scheme.toLowerCase() != 'content') {
      throw const StorageException(
        StorageException.invalidArg,
        'SAF treeUri must use content scheme',
      );
    }
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

  String _normalizeTreeUri(String treeUri) {
    final uri = Uri.parse(treeUri);
    final scheme = uri.scheme.toLowerCase();
    final authority = uri.authority.toLowerCase();
    if (authority.isEmpty) {
      return '$scheme:${uri.path}';
    }
    return '$scheme://$authority${uri.path}';
  }

  String _nextOpId() {
    _seq += 1;
    return 'saf_${_seq}_${DateTime.now().microsecondsSinceEpoch}';
  }
}
