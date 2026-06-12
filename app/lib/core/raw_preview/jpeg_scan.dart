import 'dart:typed_data';

/// Scans [bytes] for embedded JPEG streams.
///
/// Strategy:
/// - Walk the buffer looking for FFD8FF SOI markers.
/// - For each SOI found, find the last FFD9 EOI byte sequence after it to form
///   a candidate slice. (Using the *last* FFD9 after each SOI picks up the full
///   preview rather than a nested thumbnail's EOI.)
/// - Collect all valid candidates (slice starts FFD8, ends FFD9).
/// - Return the largest candidate whose length >= [minSize]; if none meets the
///   size threshold return the largest overall; if no candidates at all return
///   null.
///
/// Complexity: O(n) for the EOI pass; the SOI collection pass is also O(n).
Uint8List? findLargestEmbeddedJpeg(Uint8List bytes, {int minSize = 8192}) {
  if (bytes.length < 4) return null;

  // Collect all SOI offsets
  final soiOffsets = <int>[];
  for (int i = 0; i < bytes.length - 1; i++) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xD8) {
      soiOffsets.add(i);
    }
  }

  if (soiOffsets.isEmpty) return null;

  // Find the last EOI (FFD9) offset in the entire buffer
  // We'll compute last-EOI-after-each-SOI by scanning from the end
  // Build a sorted list of all EOI positions
  final eoiOffsets = <int>[];
  for (int i = bytes.length - 2; i >= 0; i--) {
    if (bytes[i] == 0xFF && bytes[i + 1] == 0xD9) {
      eoiOffsets.add(i + 2); // exclusive end: slice ends at i+2
    }
  }
  // eoiOffsets is in descending order; reverse for ascending
  // Actually, let's just find the last EOI after each SOI efficiently.

  if (eoiOffsets.isEmpty) return null;

  // For each SOI, find the last EOI that is after it.
  // eoiOffsets is currently in descending order (we scanned from end).
  // The first element in eoiOffsets is the largest (last in file).

  Uint8List? best;
  int bestSize = 0;
  Uint8List? bestUnderMin;
  int bestUnderMinSize = 0;

  for (final soiStart in soiOffsets) {
    // Find last EOI end > soiStart + 4 (minimum JPEG size)
    int? eoiEnd;
    for (final end in eoiOffsets) {
      // eoiOffsets is descending, so first one > soiStart is the last EOI
      if (end > soiStart + 4) {
        eoiEnd = end;
        break;
      }
    }
    if (eoiEnd == null) continue;

    // Validate slice: must start FFD8FF and end with FFD9
    if (eoiEnd > bytes.length) continue;
    final slice = Uint8List.sublistView(bytes, soiStart, eoiEnd);
    if (slice.length < 4) continue;
    // Verify SOI marker
    if (slice[0] != 0xFF || slice[1] != 0xD8) continue;
    // Verify EOI marker at end
    if (slice[slice.length - 2] != 0xFF || slice[slice.length - 1] != 0xD9) continue;

    final len = slice.length;
    if (len >= minSize) {
      if (len > bestSize) {
        bestSize = len;
        best = slice;
      }
    } else {
      if (len > bestUnderMinSize) {
        bestUnderMinSize = len;
        bestUnderMin = slice;
      }
    }
  }

  return best ?? bestUnderMin;
}
