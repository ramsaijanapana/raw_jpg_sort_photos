import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../services/local_path_classifier.dart';
import 'storage_gateway.dart';

/// Rejects empty, `/`, `\`, `.`, `..`, and NUL, matching IoStorageGateway
/// file-name rules. Cache dest names must not come from raw caller input.
void assertSafeCacheFileName(String name) {
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

/// Refuses empty, NUL, and non-local paths (including `content://`) before
/// any `File` / `Directory` construction from that string.
void assertSafeLocalPath(String path) {
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

/// Byte source for preview / thumbnail / EXIF reads.
///
/// [readAll] is a last resort. TIFF-family and RAF callers must prefer
/// [read]. Implementations must never construct `File` from a content URI.
abstract class ByteRangeReader {
  Future<int> length();

  Future<Uint8List> read(int offset, int length);

  Future<Uint8List> readAll();
}

/// Optional cache seam for CR3 / failed ranged reads when the isolate cannot
/// open the original source. Implemented by [IoByteRangeReader] and
/// [GatewayByteRangeReader].
abstract class CacheMaterializingByteRangeReader implements ByteRangeReader {
  Future<String> materializeToCache();

  Future<void> deleteCache(String cachePath);
}

/// [ByteRangeReader] over a local [File] or an already-open [RandomAccessFile].
class IoByteRangeReader implements CacheMaterializingByteRangeReader {
  IoByteRangeReader._({
    required File? file,
    required RandomAccessFile? raf,
    required this.displayName,
    required Directory? cacheDirectory,
    Future<void> Function()? injectIo,
  })  : _file = file,
        _raf = raf,
        _cacheDirectory = cacheDirectory,
        _injectIo = injectIo;

  factory IoByteRangeReader.fromFile(
    File file, {
    String? displayName,
    Directory? cacheDirectory,
    Future<void> Function()? injectIo,
  }) {
    assertSafeLocalPath(file.path);
    return IoByteRangeReader._(
      file: file,
      raf: null,
      displayName: displayName ?? p.basename(file.path),
      cacheDirectory: cacheDirectory,
      injectIo: injectIo,
    );
  }

  factory IoByteRangeReader.fromRandomAccessFile(
    RandomAccessFile raf, {
    String? displayName,
    Directory? cacheDirectory,
    Future<void> Function()? injectIo,
  }) {
    return IoByteRangeReader._(
      file: null,
      raf: raf,
      displayName: displayName ?? 'unnamed',
      cacheDirectory: cacheDirectory,
      injectIo: injectIo,
    );
  }

  final File? _file;
  final RandomAccessFile? _raf;
  final String displayName;
  final Directory? _cacheDirectory;
  final Future<void> Function()? _injectIo;

  final Set<String> _ownedCachePaths = <String>{};
  final Set<String> _retiredCachePaths = <String>{};

  /// Process-wide. Instance counters are useless: readers are one-shot.
  static int _seq = 0;

  @override
  Future<int> length() {
    return _guardIo(() async {
      final raf = _raf;
      if (raf != null) {
        return raf.length();
      }
      return _withFile((file) => file.length());
    });
  }

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0) {
      throw const StorageException(
        StorageException.invalidArg,
        'offset and length must be non-negative',
      );
    }
    return await _guardIo(() async {
      final raf = _raf;
      if (raf != null) {
        return _readFromRaf(raf, offset, length);
      }
      return _withFile((file) async {
        final opened = await file.open();
        try {
          return await _readFromRaf(opened, offset, length);
        } finally {
          await opened.close();
        }
      });
    });
  }

  @override
  Future<Uint8List> readAll() {
    return _guardIo(() async {
      final raf = _raf;
      if (raf != null) {
        final size = await raf.length();
        await raf.setPosition(0);
        return raf.read(size);
      }
      return _withFile((file) => file.readAsBytes());
    });
  }

  /// Copies a local file to a generated `ps_mat_*` name. Never uses [readAll].
  @override
  Future<String> materializeToCache() async {
    assertSafeCacheFileName(displayName);
    final file = _file;
    if (file == null) {
      throw const StorageException(
        StorageException.unsupported,
        'RandomAccessFile reader cannot materialize without a File',
      );
    }
    assertSafeLocalPath(file.path);
    final cacheDir = _cacheDirectory ?? Directory.systemTemp;
    assertSafeLocalPath(cacheDir.path);
    return _guardIo(() async {
      final cachePath = p.join(cacheDir.path, 'ps_mat_${_uniqueToken()}');
      var issued = false;
      try {
        await file.copy(cachePath);
        final copied = File(cachePath);
        if (await copied.length() != await file.length()) {
          throw const StorageException(
            StorageException.ioFailure,
            'cache copy size mismatch',
          );
        }
        _ownedCachePaths.add(cachePath);
        _retiredCachePaths.remove(cachePath);
        issued = true;
        return cachePath;
      } finally {
        if (!issued) {
          try {
            final partial = File(cachePath);
            if (await partial.exists()) {
              await partial.delete();
            }
          } catch (_) {}
        }
      }
    });
  }

  @override
  Future<void> deleteCache(String cachePath) async {
    assertSafeLocalPath(cachePath);
    if (_retiredCachePaths.contains(cachePath)) {
      return;
    }
    if (!_ownedCachePaths.contains(cachePath)) {
      throw const StorageException(
        StorageException.invalidArg,
        'cache path was not issued by this reader',
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

  Future<T> _withFile<T>(Future<T> Function(File file) action) async {
    final file = _file;
    if (file == null) {
      throw const StorageException(
        StorageException.unsupported,
        'reader has no File',
      );
    }
    assertSafeLocalPath(file.path);
    if (!await file.exists()) {
      throw StorageException(
        StorageException.notFound,
        'file not found',
        {'path': file.path},
      );
    }
    return action(file);
  }

  Future<Uint8List> _readFromRaf(
    RandomAccessFile raf,
    int offset,
    int length,
  ) async {
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
    return raf.read(toRead);
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
}

/// [ByteRangeReader] over [StorageGateway.readRange] / [byteLength] / [readAll].
///
/// Never constructs `File` from a content URI or [StorageEntry.localPath].
class GatewayByteRangeReader implements CacheMaterializingByteRangeReader {
  GatewayByteRangeReader(this.gateway, this.entry);

  final StorageGateway gateway;
  final StorageEntry entry;

  @override
  Future<int> length() => gateway.byteLength(entry);

  @override
  Future<Uint8List> read(int offset, int length) =>
      gateway.readRange(entry, offset: offset, length: length);

  @override
  Future<Uint8List> readAll() => gateway.readAll(entry);

  @override
  Future<String> materializeToCache() {
    assertSafeCacheFileName(entry.name);
    return gateway.materializeToCache(entry);
  }

  @override
  Future<void> deleteCache(String cachePath) => gateway.deleteCache(cachePath);
}
