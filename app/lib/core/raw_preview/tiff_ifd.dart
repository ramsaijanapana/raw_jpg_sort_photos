import 'dart:typed_data';

/// Attempts to extract an embedded JPEG preview from TIFF-based RAW files.
///
/// Handles:
/// - Standard TIFF (II little-endian or MM big-endian, magic 42)
/// - ORF variants (magic 0x4F52 / 0x5352)
/// - RW2 variants (magic 0x55)
///
/// Walks IFD0, IFD1 (thumbnail chain), and any SubIFDs (tag 0x014A).
/// Collects JPEG candidate data from:
/// - Tags 0x0201/0x0202 (JPEGInterchangeFormat / JPEGInterchangeFormatLength)
/// - Tags 0x0111/0x0117 (StripOffsets / StripByteCounts) when compression is 6 or 7
///
/// Returns the largest valid JPEG candidate (starts FFD8, ends FFD9), or null
/// if none found. Never throws — all errors return null.
Uint8List? extractTiffPreview(Uint8List bytes) {
  try {
    return _extractTiffPreview(bytes);
  } catch (_) {
    return null;
  }
}

Uint8List? _extractTiffPreview(Uint8List bytes) {
  if (bytes.length < 8) return null;

  // Determine byte order from first two bytes
  final b0 = bytes[0];
  final b1 = bytes[1];
  bool littleEndian;
  if (b0 == 0x49 && b1 == 0x49) {
    littleEndian = true; // 'II'
  } else if (b0 == 0x4D && b1 == 0x4D) {
    littleEndian = false; // 'MM'
  } else {
    return null; // Not a TIFF
  }

  // Magic check: accept 42 (standard), 0x4F52, 0x5352 (ORF), 0x55 (RW2), 0x004F (ORF alt)
  // We read the magic but accept any value for flexibility with camera variants.
  // (ORF uses 0x4F52/0x5352, RW2 uses 0x55 — all handled by walking the IFD.)
  _readU16(bytes, 2, littleEndian); // magic — validated implicitly

  // IFD0 offset
  if (bytes.length < 8) return null;
  final ifd0Offset = _readU32(bytes, 4, littleEndian);

  final candidates = <Uint8List>[];
  final visited = <int>{};

  _walkIfdChain(bytes, ifd0Offset, littleEndian, candidates, visited, depth: 0);

  if (candidates.isEmpty) return null;

  // Return the largest valid JPEG
  candidates.sort((a, b) => b.length.compareTo(a.length));
  return candidates.first;
}

void _walkIfdChain(
  Uint8List bytes,
  int offset,
  bool le,
  List<Uint8List> candidates,
  Set<int> visited, {
  required int depth,
}) {
  if (depth > 8) return; // Guard against infinite loops
  while (offset != 0 && !visited.contains(offset)) {
    visited.add(offset);
    offset = _walkIfd(bytes, offset, le, candidates, visited, depth: depth);
    depth++;
  }
}

/// Walks one IFD, collects candidates, and returns the next-IFD offset.
int _walkIfd(
  Uint8List bytes,
  int offset,
  bool le,
  List<Uint8List> candidates,
  Set<int> visited, {
  required int depth,
}) {
  if (offset < 0 || offset + 2 > bytes.length) return 0;

  final entryCount = _readU16(bytes, offset, le);
  if (entryCount == 0 || entryCount > 4096) return 0;

  final entriesEnd = offset + 2 + entryCount * 12;
  if (entriesEnd + 4 > bytes.length) return 0;

  // Collect relevant tag values first
  int jpegOffset = 0;
  int jpegLength = 0;
  int stripOffset = 0;
  int stripByteCount = 0;
  int compression = 0;

  for (int i = 0; i < entryCount; i++) {
    final entryOffset = offset + 2 + i * 12;
    if (entryOffset + 12 > bytes.length) break;

    final tag = _readU16(bytes, entryOffset, le);
    final type = _readU16(bytes, entryOffset + 2, le);
    final count = _readU32(bytes, entryOffset + 4, le);
    final valueOrOffset = entryOffset + 8;

    switch (tag) {
      case 0x0103: // Compression
        compression = _readTagValue(bytes, type, count, valueOrOffset, le);
        break;
      case 0x0111: // StripOffsets
        stripOffset = _readTagValue(bytes, type, count, valueOrOffset, le);
        break;
      case 0x0117: // StripByteCounts
        stripByteCount = _readTagValue(bytes, type, count, valueOrOffset, le);
        break;
      case 0x0201: // JPEGInterchangeFormat
        jpegOffset = _readTagValue(bytes, type, count, valueOrOffset, le);
        break;
      case 0x0202: // JPEGInterchangeFormatLength
        jpegLength = _readTagValue(bytes, type, count, valueOrOffset, le);
        break;
      case 0x014A: // SubIFD(s)
        _processSubIfd(bytes, type, count, valueOrOffset, le, candidates, visited, depth: depth + 1);
        break;
    }
  }

  // Collect JPEG interchange format candidate
  if (jpegOffset > 0 && jpegLength > 0) {
    final slice = _safeSlice(bytes, jpegOffset, jpegOffset + jpegLength);
    if (slice != null && _isValidJpeg(slice)) {
      candidates.add(slice);
    }
  } else if (jpegOffset > 0) {
    // No length given — scan for the JPEG from offset
    final slice = _scanJpegFrom(bytes, jpegOffset);
    if (slice != null) candidates.add(slice);
  }

  // Collect strip-based JPEG (JPEG-compressed strip)
  if (stripOffset > 0 && stripByteCount > 0 && (compression == 6 || compression == 7)) {
    final slice = _safeSlice(bytes, stripOffset, stripOffset + stripByteCount);
    if (slice != null && _isValidJpeg(slice)) {
      candidates.add(slice);
    }
  }

  // Return next-IFD offset
  final nextIfdOffset = _readU32(bytes, entriesEnd, le);
  return nextIfdOffset;
}

void _processSubIfd(
  Uint8List bytes,
  int type,
  int count,
  int valueOrOffset,
  bool le,
  List<Uint8List> candidates,
  Set<int> visited, {
  required int depth,
}) {
  if (depth > 8) return;
  // Each SubIFD entry is a 4-byte offset
  // If count == 1 and fits in 4 bytes, value is inline; else it's an offset to array
  if (count == 1) {
    final subOffset = _readU32(bytes, valueOrOffset, le);
    if (subOffset > 0) {
      _walkIfdChain(bytes, subOffset, le, candidates, visited, depth: depth);
    }
  } else {
    // Multiple SubIFDs: valueOrOffset is a pointer to array of offsets
    final arrayOffset = _readU32(bytes, valueOrOffset, le);
    for (int i = 0; i < count && i < 16; i++) {
      final pos = arrayOffset + i * 4;
      if (pos + 4 > bytes.length) break;
      final subOffset = _readU32(bytes, pos, le);
      if (subOffset > 0) {
        _walkIfdChain(bytes, subOffset, le, candidates, visited, depth: depth);
      }
    }
  }
}

/// Reads a scalar tag value (first value only) given TIFF type and count.
/// Returns 0 on any error.
int _readTagValue(Uint8List bytes, int type, int count, int valueOrOffset, bool le) {
  if (count == 0) return 0;
  switch (type) {
    case 1: // BYTE (1 byte)
    case 6: // SBYTE
      return _safeByte(bytes, valueOrOffset);
    case 3: // SHORT (2 bytes)
    case 8: // SSHORT
      if (valueOrOffset + 2 > bytes.length) return 0;
      return _readU16(bytes, valueOrOffset, le);
    case 4: // LONG (4 bytes)
    case 9: // SLONG
      if (valueOrOffset + 4 > bytes.length) return 0;
      return _readU32(bytes, valueOrOffset, le);
    case 2: // ASCII
      return 0;
    default:
      // For unknown types, try reading as 4-byte
      if (valueOrOffset + 4 > bytes.length) return 0;
      return _readU32(bytes, valueOrOffset, le);
  }
}

/// Returns a sublist of [bytes] from [start] to [end], or null if out of bounds.
Uint8List? _safeSlice(Uint8List bytes, int start, int end) {
  if (start < 0 || end <= start || end > bytes.length) return null;
  return Uint8List.sublistView(bytes, start, end);
}

/// Returns true if [slice] is a valid JPEG (starts FFD8, ends FFD9).
bool _isValidJpeg(Uint8List slice) {
  if (slice.length < 4) return false;
  if (slice[0] != 0xFF || slice[1] != 0xD8) return false;
  if (slice[slice.length - 2] != 0xFF || slice[slice.length - 1] != 0xD9) return false;
  return true;
}

/// Scans forward from [offset] looking for a JPEG stream (FFD8) and its EOI.
Uint8List? _scanJpegFrom(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return null;
  if (bytes[offset] != 0xFF || bytes[offset + 1] != 0xD8) return null;

  // Find EOI
  for (int i = offset + 2; i < bytes.length - 1; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
      final slice = Uint8List.sublistView(bytes, offset, i + 2);
      if (_isValidJpeg(slice)) return slice;
    }
  }
  return null;
}

int _safeByte(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) return 0;
  return bytes[offset];
}

int _readU16(Uint8List bytes, int offset, bool le) {
  if (offset < 0 || offset + 2 > bytes.length) return 0;
  if (le) {
    return bytes[offset] | (bytes[offset + 1] << 8);
  } else {
    return (bytes[offset] << 8) | bytes[offset + 1];
  }
}

int _readU32(Uint8List bytes, int offset, bool le) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;
  if (le) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  } else {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }
}
