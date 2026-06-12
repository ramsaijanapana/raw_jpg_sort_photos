import 'dart:io';
import 'dart:typed_data';
import 'jpeg_scan.dart';
import 'tiff_ifd.dart';

/// Extracts a JPEG preview from [rawFile].
///
/// Delegates to [extractPreviewBytes] after reading the file.
Future<Uint8List?> extractPreview(File rawFile) async {
  final bytes = await rawFile.readAsBytes();
  final ext = _extensionOf(rawFile.path).toLowerCase();
  return extractPreviewBytes(bytes, ext);
}

/// Extracts a JPEG preview from [bytes] for a file with the given [extension].
///
/// Extension should be lowercase with leading dot, e.g. '.cr2'.
///
/// Dispatches to format-specific extractors, always falling back to
/// [findLargestEmbeddedJpeg] if the format-specific method returns null.
Uint8List? extractPreviewBytes(Uint8List bytes, String extension) {
  final ext = extension.toLowerCase();

  Uint8List? result;

  if (ext == '.cr3') {
    result = _extractCr3Preview(bytes);
  } else if (ext == '.raf') {
    result = _extractRafPreview(bytes);
  } else {
    // TIFF-based: ARW, CR2, NEF, ORF, DNG, RW2, PEF, SRW
    result = extractTiffPreview(bytes);
  }

  // Fall back to brute-force JPEG scan when the format-specific path found
  // nothing, or found only a small thumbnail (some cameras store a tiny
  // ~160x120 thumb in IFD1 while the real preview lives elsewhere).
  if (result == null || result.length < _smallPreviewThreshold) {
    final scanned = findLargestEmbeddedJpeg(bytes);
    if (scanned != null && scanned.length > (result?.length ?? 0)) {
      result = scanned;
    }
  }
  return result;
}

/// Previews smaller than this are treated as thumbnails, prompting a scan
/// for a larger embedded JPEG.
const int _smallPreviewThreshold = 65536;

// ──────────────────────────────────────────────────────────────────────────────
// CR3 (ISO Base Media File Format / BMFF)
// ──────────────────────────────────────────────────────────────────────────────

/// Extracts a preview from a CR3 file by walking ISO BMFF boxes.
///
/// Looks inside 'moov' and 'uuid' boxes for a 'PRVW' box (Canon preview).
/// Falls back to null if not found (caller will then use jpeg scan).
Uint8List? _extractCr3Preview(Uint8List bytes) {
  try {
    return _walkBmffBoxes(bytes, 0, bytes.length, depth: 0);
  } catch (_) {
    return null;
  }
}

Uint8List? _walkBmffBoxes(Uint8List bytes, int start, int end, {required int depth}) {
  if (depth > 12) return null;
  int offset = start;

  while (offset + 8 <= end) {
    // Read box size (4 bytes BE) and type (4 bytes ASCII)
    final size = _readU32Be(bytes, offset);
    final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

    if (size == 0) break; // box extends to end of file — treat as terminal
    if (size < 8) break; // malformed

    final boxEnd = offset + size;
    if (boxEnd > end + 1) break; // malformed (allow slight overrun)

    final safeEnd = boxEnd.clamp(0, bytes.length);

    // Check for PRVW box (Canon CR3 preview)
    if (type == 'PRVW') {
      // PRVW: 4 bytes unknown, 2 bytes width, 2 bytes height, 4 bytes jpeg size, then JPEG data
      final dataStart = offset + 8;
      if (dataStart + 12 <= safeEnd) {
        final jpegSize = _readU32Be(bytes, dataStart + 8);
        final jpegStart = dataStart + 12;
        final jpegEnd = jpegStart + jpegSize;
        if (jpegStart < jpegEnd && jpegEnd <= bytes.length) {
          final slice = Uint8List.sublistView(bytes, jpegStart, jpegEnd);
          if (slice.length >= 4 && slice[0] == 0xFF && slice[1] == 0xD8) {
            return slice;
          }
        }
      }
    }

    // Recurse into container boxes
    if (type == 'moov' ||
        type == 'trak' ||
        type == 'mdia' ||
        type == 'minf' ||
        type == 'dinf' ||
        type == 'stbl' ||
        type == 'uuid') {
      final innerStart = (type == 'uuid') ? offset + 8 + 16 : offset + 8;
      if (innerStart < safeEnd) {
        final inner = _walkBmffBoxes(bytes, innerStart, safeEnd, depth: depth + 1);
        if (inner != null) return inner;
      }
    }

    offset = boxEnd;
  }
  return null;
}

int _readU32Be(Uint8List bytes, int offset) {
  if (offset + 4 > bytes.length) return 0;
  return (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];
}

// ──────────────────────────────────────────────────────────────────────────────
// RAF (Fujifilm)
// ──────────────────────────────────────────────────────────────────────────────

/// Extracts a preview from a Fujifilm RAF file.
///
/// RAF embeds a JPEG preview at a known offset stored in the file header:
/// bytes 84-87 (big-endian u32) = offset, bytes 88-91 = length.
Uint8List? _extractRafPreview(Uint8List bytes) {
  try {
    if (bytes.length < 92) return null;

    final offset = _readU32Be(bytes, 84);
    final length = _readU32Be(bytes, 88);

    if (offset == 0 || length == 0) return null;
    if (offset + length > bytes.length) return null;

    final slice = Uint8List.sublistView(bytes, offset, offset + length);
    if (slice.length >= 2 && slice[0] == 0xFF && slice[1] == 0xD8) {
      return slice;
    }
    return null;
  } catch (_) {
    return null;
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

String _extensionOf(String path) {
  final idx = path.lastIndexOf('.');
  if (idx < 0 || idx == path.length - 1) return '';
  return path.substring(idx);
}
