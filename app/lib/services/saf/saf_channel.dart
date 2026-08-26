import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../../core/folder_ref.dart';
import '../../core/storage/storage_gateway.dart';

/// Result of [SafChannel.pickTree].
class SafPickResult {
  const SafPickResult({
    required this.tree,
    required this.writeGranted,
  });

  final SafTree tree;
  final bool writeGranted;
}

/// Dart client for the Android SAF [MethodChannel].
///
/// Every [PlatformException] becomes a [StorageException]. Host registration
/// is Task 08E.
class SafChannel {
  SafChannel([MethodChannel? channel])
      : channel = channel ?? const MethodChannel(channelName) {
    if (this.channel.name != channelName) {
      throw ArgumentError.value(
        this.channel.name,
        'channel.name',
        'must be $channelName',
      );
    }
  }

  static const channelName = 'com.photosorter.photo_sorter/saf';

  static const _acceptedCodes = {
    StorageException.alreadyExists,
    StorageException.cancelled,
    StorageException.incompleteMove,
    StorageException.invalidArg,
    StorageException.ioFailure,
    StorageException.notFound,
    StorageException.permissionDenied,
    StorageException.quota,
    StorageException.readOnly,
    StorageException.unsupported,
  };

  final MethodChannel channel;

  Future<SafPickResult?> pickTree({String? title}) async {
    try {
      final raw = await channel.invokeMethod<Object>(
        'pickTree',
        title == null ? <String, Object?>{} : <String, Object?>{'title': title},
      );
      if (raw == null) return null;
      return _decodePick(raw);
    } on PlatformException catch (e) {
      if (e.code == 'cancel') return null;
      throw mapPlatformException(e);
    }
  }

  Future<void> takePersistable(String treeUri) {
    return _invokeOk('takePersistable', <String, Object?>{'treeUri': treeUri});
  }

  Future<void> releasePersistable(String treeUri) {
    return _invokeOk(
      'releasePersistable',
      <String, Object?>{'treeUri': treeUri},
    );
  }

  Future<List<SafTree>> persistedTrees() async {
    final raw = await _invoke('persistedTrees', <String, Object?>{});
    final map = _asMap(raw, context: 'persistedTrees');
    final trees = map['trees'];
    if (trees is! List) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing trees',
      );
    }
    return trees.map(_decodeTree).toList();
  }

  Future<bool> hasPersisted(String treeUri) async {
    final raw = await _invoke(
      'hasPersisted',
      <String, Object?>{'treeUri': treeUri},
    );
    final ok = _asMap(raw, context: 'hasPersisted')['ok'];
    if (ok is! bool) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing ok',
      );
    }
    return ok;
  }

  Future<List<StorageEntry>> listChildren({
    required String treeUri,
    required String documentId,
    required FolderRef folder,
  }) async {
    final raw = await _invoke(
      'listChildren',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
      },
    );
    final map = _asMap(raw, context: 'listChildren');
    final entries = map['entries'];
    if (entries is! List) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing entries',
      );
    }
    return entries.map((item) => decodeEntry(item, folder)).toList();
  }

  Future<StorageEntry?> childByName({
    required String treeUri,
    required String parentDocumentId,
    required String name,
    required FolderRef folder,
  }) async {
    final raw = await _invoke(
      'childByName',
      <String, Object?>{
        'treeUri': treeUri,
        'parentDocumentId': parentDocumentId,
        'name': name,
      },
    );
    final entry = _asMap(raw, context: 'childByName')['entry'];
    if (entry == null) return null;
    return decodeEntry(entry, folder);
  }

  Future<StorageEntry> createDirectory({
    required String treeUri,
    required String parentDocumentId,
    required String name,
    required FolderRef folder,
  }) async {
    final raw = await _invoke(
      'createDirectory',
      <String, Object?>{
        'treeUri': treeUri,
        'parentDocumentId': parentDocumentId,
        'name': name,
      },
    );
    return decodeEntry(
      _asMap(raw, context: 'createDirectory')['entry'],
      folder,
    );
  }

  Future<StorageEntry> createFile({
    required String treeUri,
    required String parentDocumentId,
    required String displayName,
    required String mimeType,
    required FolderRef folder,
  }) async {
    final raw = await _invoke(
      'createFile',
      <String, Object?>{
        'treeUri': treeUri,
        'parentDocumentId': parentDocumentId,
        'displayName': displayName,
        'mimeType': mimeType,
      },
    );
    final entry = _asMap(
      _asMap(raw, context: 'createFile')['entry'],
      context: 'entry',
    );
    if (!entry.containsKey('mimeType')) {
      entry['mimeType'] = mimeType;
    }
    return decodeEntry(entry, folder);
  }

  Future<void> delete({
    required String treeUri,
    required String documentId,
  }) {
    return _invokeOk(
      'delete',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
      },
    );
  }

  Future<({String? outcome, StorageEntry entry})> move({
    required String treeUri,
    required String documentId,
    required String? sourceParentId,
    required String destParentId,
    required String destName,
    required FolderRef folder,
  }) async {
    final raw = await _invoke(
      'move',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
        'sourceParentId': sourceParentId,
        'destParentId': destParentId,
        'destName': destName,
      },
    );
    final map = _asMap(raw, context: 'move');
    final outcomeRaw = map['outcome'];
    return (
      outcome: outcomeRaw is String ? outcomeRaw : null,
      entry: decodeEntry(map['entry'], folder),
    );
  }

  Future<({StorageEntry entry, int bytesCopied})> copyTo({
    required String srcTreeUri,
    required String srcDocumentId,
    required String destTreeUri,
    required String destParentId,
    required String destName,
    required bool overwrite,
    required String opId,
    required FolderRef destFolder,
  }) async {
    final raw = await _invoke(
      'copyTo',
      <String, Object?>{
        'srcTreeUri': srcTreeUri,
        'srcDocumentId': srcDocumentId,
        'destTreeUri': destTreeUri,
        'destParentId': destParentId,
        'destName': destName,
        'overwrite': overwrite,
        'opId': opId,
      },
    );
    final map = _asMap(raw, context: 'copyTo');
    return (
      entry: decodeEntry(map['entry'], destFolder),
      bytesCopied: _requireInt(map['bytesCopied'], 'bytesCopied'),
    );
  }

  Future<Uint8List> readRange({
    required String treeUri,
    required String documentId,
    required int offset,
    required int length,
  }) async {
    final raw = await _invoke(
      'readRange',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
        'offset': offset,
        'length': length,
      },
    );
    if (raw == null) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing byte payload',
      );
    }
    if (raw is! Uint8List) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing byte payload',
      );
    }
    return raw;
  }

  Future<int> byteLength({
    required String treeUri,
    required String documentId,
  }) async {
    final raw = await _invoke(
      'byteLength',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
      },
    );
    return _requireInt(_asMap(raw, context: 'byteLength')['size'], 'size');
  }

  Future<void> writeBytes({
    required String treeUri,
    required String documentId,
    required Uint8List bytes,
  }) {
    return _invokeOk(
      'writeBytes',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
        'bytes': bytes,
      },
    );
  }

  Future<({String cachePath, int size})> materializeToCache({
    required String treeUri,
    required String documentId,
    required String opId,
  }) async {
    final raw = await _invoke(
      'materializeToCache',
      <String, Object?>{
        'treeUri': treeUri,
        'documentId': documentId,
        'opId': opId,
      },
    );
    final map = _asMap(raw, context: 'materializeToCache');
    final cachePath = map['cachePath'];
    if (cachePath is! String ||
        cachePath.isEmpty ||
        cachePath.contains('\x00')) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing cachePath',
      );
    }
    return (
      cachePath: cachePath,
      size: _requireInt(map['size'], 'size'),
    );
  }

  Future<void> deleteCache(String cachePath) {
    return _invokeOk(
      'deleteCache',
      <String, Object?>{'cachePath': cachePath},
    );
  }

  Future<void> cancel(String opId) {
    return _invokeOk('cancel', <String, Object?>{'opId': opId});
  }

  StorageEntry decodeEntry(Object? raw, FolderRef folder) {
    final map = _asMap(raw, context: 'entry');
    final documentId = map['documentId'];
    if (documentId is! String ||
        documentId.isEmpty ||
        documentId.contains('\x00')) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing documentId',
      );
    }
    final displayName = map['displayName'];
    if (displayName is! String) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing displayName',
      );
    }
    final mimeRaw = map['mimeType'];
    final isDirRaw = map['isDirectory'];
    final bool isDirectory;
    if (isDirRaw is bool) {
      isDirectory = isDirRaw;
    } else {
      isDirectory = mimeRaw == StorageEntry.directoryMimeType;
    }
    final String mimeType;
    if (mimeRaw is String && mimeRaw.isNotEmpty) {
      mimeType = mimeRaw;
    } else if (isDirectory) {
      mimeType = StorageEntry.directoryMimeType;
    } else {
      mimeType = 'application/octet-stream';
    }
    final sizeRaw = map['size'];
    return StorageEntry(
      folder: folder,
      name: displayName,
      documentId: documentId,
      localPath: null,
      mimeType: mimeType,
      size: sizeRaw is int ? sizeRaw : null,
      isDirectory: isDirectory,
    );
  }

  StorageException mapPlatformException(PlatformException e) {
    final String code;
    final String? remappedFrom;
    if (_acceptedCodes.contains(e.code)) {
      code = e.code;
      remappedFrom = null;
    } else if (e.code == 'cancel') {
      code = StorageException.cancelled;
      remappedFrom = 'cancel';
    } else if (e.code == 'not_a_tree') {
      code = StorageException.invalidArg;
      remappedFrom = 'not_a_tree';
    } else {
      code = StorageException.ioFailure;
      remappedFrom = e.code;
    }
    return StorageException(
      code,
      e.message ?? '',
      _mapDetails(e.details, remappedFrom),
    );
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await channel.invokeMethod<Object>(method, arguments);
    } on PlatformException catch (e) {
      throw mapPlatformException(e);
    }
  }

  Future<void> _invokeOk(
    String method,
    Map<String, Object?> arguments,
  ) async {
    final raw = await _invoke(method, arguments);
    if (_asMap(raw, context: method)['ok'] != true) {
      throw const StorageException(
        StorageException.ioFailure,
        'expected ok',
      );
    }
  }

  SafPickResult _decodePick(Object raw) {
    final map = _asMap(raw, context: 'pickTree');
    final granted = map['writeGranted'];
    return SafPickResult(
      tree: _decodeTree(map),
      writeGranted: granted is bool ? granted : true,
    );
  }

  SafTree _decodeTree(Object? raw) {
    final map = _asMap(raw, context: 'tree');
    final treeUri = map['treeUri'];
    final documentId = map['documentId'];
    if (treeUri is! String || treeUri.isEmpty) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing treeUri',
      );
    }
    if (documentId is! String) {
      throw const StorageException(
        StorageException.ioFailure,
        'missing documentId',
      );
    }
    final displayName = map['displayName'];
    return SafTree(
      treeUri: treeUri,
      documentId: documentId,
      displayName: displayName is String ? displayName : '',
    );
  }

  Map<String, Object?> _asMap(Object? raw, {required String context}) {
    if (raw == null || raw is! Map) {
      throw StorageException(
        StorageException.ioFailure,
        'missing $context',
      );
    }
    return Map<String, Object?>.from(raw);
  }

  int _requireInt(Object? value, String key) {
    if (value is! int) {
      throw StorageException(
        StorageException.ioFailure,
        'missing $key',
      );
    }
    return value;
  }

  Map<String, Object?>? _mapDetails(dynamic details, String? remappedFrom) {
    if (details is Map) {
      final mapped = Map<String, Object?>.from(details);
      if (remappedFrom != null) {
        mapped['platformCode'] = remappedFrom;
      }
      return mapped;
    }
    if (details == null) {
      if (remappedFrom != null) {
        return <String, Object?>{'platformCode': remappedFrom};
      }
      return null;
    }
    final mapped = <String, Object?>{'platformDetails': details};
    if (remappedFrom != null) {
      mapped['platformCode'] = remappedFrom;
    }
    return mapped;
  }
}
