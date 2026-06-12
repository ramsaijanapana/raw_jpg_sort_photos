import 'dart:typed_data';

/// Compact summary of EXIF metadata extracted from a photo.
class ExifSummary {
  const ExifSummary({
    this.camera,
    this.shutter,
    this.aperture,
    this.iso,
    this.focal,
  });

  final String? camera;
  final String? shutter;
  final String? aperture;
  final String? iso;
  final String? focal;

  /// Human-readable single line joining non-null parts with ' · '.
  String get line {
    final parts = <String>[
      ?camera,
      ?shutter,
      ?aperture,
      ?iso,
      ?focal,
    ];
    return parts.join(' · ');
  }

  bool get isEmpty =>
      camera == null &&
      shutter == null &&
      aperture == null &&
      iso == null &&
      focal == null;
}

/// Parses EXIF metadata from [bytes] (JPEG or TIFF-based RAW).
///
/// Returns null when no EXIF data is found or on any error. Never throws.
ExifSummary? readExifSummary(Uint8List bytes) {
  try {
    return _readExifSummary(bytes);
  } catch (_) {
    return null;
  }
}

ExifSummary? _readExifSummary(Uint8List bytes) {
  if (bytes.length < 12) return null;

  // ── Detect format ──────────────────────────────────────────────────────────
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
    // JPEG: scan APP1 (FFE1) segments for 'Exif\0\0' marker
    return _parseJpegExif(bytes);
  }

  // TIFF-based RAW (II or MM)
  if ((bytes[0] == 0x49 && bytes[1] == 0x49) ||
      (bytes[0] == 0x4D && bytes[1] == 0x4D)) {
    return _parseTiffExif(bytes, 0);
  }

  return null;
}

// ─── JPEG parsing ─────────────────────────────────────────────────────────────

ExifSummary? _parseJpegExif(Uint8List bytes) {
  int pos = 2; // skip SOI FF D8
  while (pos + 4 <= bytes.length) {
    if (bytes[pos] != 0xFF) break;
    final marker = bytes[pos + 1];
    if (marker == 0xD9 || marker == 0xDA) break; // EOI / SOS

    if (pos + 4 > bytes.length) break;
    final segLen = _u16be(bytes, pos + 2); // segment length includes the 2 length bytes
    final segEnd = pos + 2 + segLen;

    if (marker == 0xE1 && segLen >= 8) {
      // APP1 — check for 'Exif\0\0'
      final dataStart = pos + 4;
      if (dataStart + 6 <= bytes.length &&
          bytes[dataStart] == 0x45 && // 'E'
          bytes[dataStart + 1] == 0x78 && // 'x'
          bytes[dataStart + 2] == 0x69 && // 'i'
          bytes[dataStart + 3] == 0x66 && // 'f'
          bytes[dataStart + 4] == 0x00 &&
          bytes[dataStart + 5] == 0x00) {
        // TIFF blob starts at dataStart + 6
        final tiffOffset = dataStart + 6;
        if (tiffOffset < bytes.length) {
          final tiffData = Uint8List.sublistView(bytes, tiffOffset);
          return _parseTiffExif(tiffData, 0);
        }
      }
    }

    pos = segEnd;
  }
  return null;
}

// ─── TIFF/Exif parsing ────────────────────────────────────────────────────────

ExifSummary? _parseTiffExif(Uint8List bytes, int baseOffset) {
  if (bytes.length < 8) return null;

  final b0 = bytes[0], b1 = bytes[1];
  final bool le;
  if (b0 == 0x49 && b1 == 0x49) {
    le = true;
  } else if (b0 == 0x4D && b1 == 0x4D) {
    le = false;
  } else {
    return null;
  }

  final ifd0Offset = _u32(bytes, 4, le);
  if (ifd0Offset >= bytes.length) return null;

  // Read IFD0 for camera model (0x0110) and ExifIFD pointer (0x8769)
  String? camera;
  int exifIfdOffset = 0;

  final ifd0Tags = _readIfdTags(bytes, ifd0Offset, le);
  for (final tag in ifd0Tags) {
    if (tag.tag == 0x0110) {
      // Model - ASCII string
      camera = _readAsciiTag(bytes, tag, le);
    } else if (tag.tag == 0x8769) {
      // ExifIFD pointer
      exifIfdOffset = _resolveTagValue(bytes, tag, le);
    }
  }

  // Read ExifIFD for exposure tags
  String? shutter;
  String? aperture;
  String? isoStr;
  String? focal;

  if (exifIfdOffset > 0 && exifIfdOffset < bytes.length) {
    final exifTags = _readIfdTags(bytes, exifIfdOffset, le);
    for (final tag in exifTags) {
      switch (tag.tag) {
        case 0x829A: // ExposureTime
          final r = _readRational(bytes, tag, le);
          if (r != null) shutter = _formatExposureTime(r.$1, r.$2);
          break;
        case 0x829D: // FNumber
          final r = _readRational(bytes, tag, le);
          if (r != null) aperture = _formatFNumber(r.$1, r.$2);
          break;
        case 0x8827: // ISOSpeedRatings
          final v = _resolveTagValue(bytes, tag, le);
          if (v > 0) isoStr = 'ISO $v';
          break;
        case 0x920A: // FocalLength
          final r = _readRational(bytes, tag, le);
          if (r != null) focal = _formatFocalLength(r.$1, r.$2);
          break;
      }
    }
  }

  final summary = ExifSummary(
    camera: camera?.trim().isEmpty == true ? null : camera?.trim(),
    shutter: shutter,
    aperture: aperture,
    iso: isoStr,
    focal: focal,
  );

  return summary.isEmpty ? null : summary;
}

// ─── IFD helpers ──────────────────────────────────────────────────────────────

class _IfdEntry {
  const _IfdEntry(this.tag, this.type, this.count, this.valueOrOffset);
  final int tag;
  final int type;
  final int count;
  final int valueOrOffset; // byte offset of 4-byte value/offset field in [bytes]
}

List<_IfdEntry> _readIfdTags(Uint8List bytes, int offset, bool le) {
  final result = <_IfdEntry>[];
  if (offset + 2 > bytes.length) return result;
  final count = _u16(bytes, offset, le);
  if (count == 0 || count > 4096) return result;
  for (int i = 0; i < count; i++) {
    final e = offset + 2 + i * 12;
    if (e + 12 > bytes.length) break;
    final tag = _u16(bytes, e, le);
    final type = _u16(bytes, e + 2, le);
    final cnt = _u32(bytes, e + 4, le);
    result.add(_IfdEntry(tag, type, cnt, e + 8));
  }
  return result;
}

/// Reads the 32-bit scalar from a tag's value-or-offset field.
int _resolveTagValue(Uint8List bytes, _IfdEntry tag, bool le) {
  if (tag.count == 0) return 0;
  switch (tag.type) {
    case 1: // BYTE
    case 6: // SBYTE
      if (tag.valueOrOffset >= bytes.length) return 0;
      return bytes[tag.valueOrOffset];
    case 3: // SHORT
    case 8: // SSHORT
      if (tag.valueOrOffset + 2 > bytes.length) return 0;
      return _u16(bytes, tag.valueOrOffset, le);
    case 4: // LONG
    case 9: // SLONG
      if (tag.valueOrOffset + 4 > bytes.length) return 0;
      return _u32(bytes, tag.valueOrOffset, le);
    default:
      if (tag.valueOrOffset + 4 > bytes.length) return 0;
      return _u32(bytes, tag.valueOrOffset, le);
  }
}

/// Reads ASCII string tag. For short strings the value is inline; for longer
/// ones it is at the offset stored in the value field.
String? _readAsciiTag(Uint8List bytes, _IfdEntry tag, bool le) {
  if (tag.type != 2 || tag.count == 0) return null;
  int start;
  if (tag.count <= 4) {
    start = tag.valueOrOffset;
  } else {
    if (tag.valueOrOffset + 4 > bytes.length) return null;
    start = _u32(bytes, tag.valueOrOffset, le);
  }
  final end = start + tag.count;
  if (start < 0 || end > bytes.length) return null;
  // ASCII is null-terminated; trim the null and any trailing spaces.
  final chars = <int>[];
  for (int i = start; i < end; i++) {
    if (bytes[i] == 0) break;
    chars.add(bytes[i]);
  }
  return String.fromCharCodes(chars).trim();
}

/// Reads a RATIONAL (type 5) or SRATIONAL (type 10) tag.
/// Returns (numerator, denominator) or null.
(int, int)? _readRational(Uint8List bytes, _IfdEntry tag, bool le) {
  // type 5 = RATIONAL (unsigned), type 10 = SRATIONAL (signed)
  if (tag.type != 5 && tag.type != 10) return null;
  if (tag.count == 0) return null;

  // RATIONAL is 8 bytes; never fits inline — value field holds an offset.
  if (tag.valueOrOffset + 4 > bytes.length) return null;
  final offset = _u32(bytes, tag.valueOrOffset, le);
  if (offset + 8 > bytes.length) return null;

  final num = _u32(bytes, offset, le);
  final den = _u32(bytes, offset + 4, le);
  return (num, den);
}

// ─── Formatting helpers ───────────────────────────────────────────────────────

String _formatExposureTime(int num, int den) {
  if (den == 0) return '';
  if (num == 0) return '';
  if (num >= den) {
    // >= 1 second
    final secs = num / den;
    if (secs == secs.truncateToDouble()) {
      return '${secs.toInt()}s';
    }
    return '${secs.toStringAsFixed(1)}s';
  }
  // < 1 second: simplify fraction
  final g = _gcd(num, den);
  final n = num ~/ g;
  final d = den ~/ g;
  return '1/${d ~/ n}s';
}

String _formatFNumber(int num, int den) {
  if (den == 0) return '';
  final f = num / den;
  if (f == f.truncateToDouble()) {
    return 'f/${f.toInt()}';
  }
  return 'f/${f.toStringAsFixed(1)}';
}

String _formatFocalLength(int num, int den) {
  if (den == 0) return '';
  final f = num / den;
  if (f == f.truncateToDouble()) {
    return '${f.toInt()}mm';
  }
  return '${f.toStringAsFixed(0)}mm';
}

int _gcd(int a, int b) {
  while (b != 0) {
    final t = b;
    b = a % b;
    a = t;
  }
  return a;
}

// ─── Low-level byte readers ───────────────────────────────────────────────────

int _u16be(Uint8List b, int off) {
  if (off + 2 > b.length) return 0;
  return (b[off] << 8) | b[off + 1];
}

int _u16(Uint8List b, int off, bool le) {
  if (off + 2 > b.length) return 0;
  return le
      ? b[off] | (b[off + 1] << 8)
      : (b[off] << 8) | b[off + 1];
}

int _u32(Uint8List b, int off, bool le) {
  if (off + 4 > b.length) return 0;
  return le
      ? b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)
      : (b[off] << 24) | (b[off + 1] << 16) | (b[off + 2] << 8) | b[off + 3];
}
