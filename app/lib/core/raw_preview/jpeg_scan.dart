import 'dart:typed_data';

/// Scans [bytes] for embedded JPEG streams.
///
/// Strategy:
/// - Walk the buffer looking for FFD8 SOI markers.
/// - For each SOI, structurally validate the stream: walk marker segments
///   (APPn/DQT/SOF/DHT/...) using their declared lengths until SOS, then scan
///   the entropy-coded data for the EOI, skipping byte stuffing (FF00) and
///   restart markers (FFD0-FFD7). Candidates with invalid marker structure
///   are rejected outright — RAW sensor data regularly contains FFD8 byte
///   pairs that are not JPEGs.
/// - Return the largest valid candidate whose length >= [minSize]; if none
///   meets the threshold return the largest overall; else null.
Uint8List? findLargestEmbeddedJpeg(Uint8List bytes, {int minSize = 8192}) {
  if (bytes.length < 4) return null;

  Uint8List? best;
  int bestSize = 0;
  Uint8List? bestUnderMin;
  int bestUnderMinSize = 0;

  for (int i = 0; i < bytes.length - 3; i++) {
    if (bytes[i] != 0xFF || bytes[i + 1] != 0xD8) continue;

    final end = _validateJpegAt(bytes, i);
    if (end == null) continue;

    final slice = Uint8List.sublistView(bytes, i, end);
    final len = slice.length;
    if (len >= minSize) {
      if (len > bestSize) {
        bestSize = len;
        best = slice;
      }
    } else if (len > bestUnderMinSize) {
      bestUnderMinSize = len;
      bestUnderMin = slice;
    }

    // Skip past this JPEG; nested thumbnails inside its EXIF segment are
    // smaller than the enclosing stream, so they can never win anyway.
    i = end - 1;
  }

  return best ?? bestUnderMin;
}

/// Validates a JPEG starting at [start] (which must point at FFD8).
///
/// Returns the exclusive end offset of the stream (just past FFD9), or null
/// if the marker structure is invalid or the stream is truncated.
int? _validateJpegAt(Uint8List bytes, int start) {
  int pos = start + 2; // past SOI

  // Segment walk until SOS (FFDA).
  while (true) {
    if (pos + 4 > bytes.length) return null;
    if (bytes[pos] != 0xFF) return null;

    // Skip fill bytes (FF FF ... marker).
    int marker = bytes[pos + 1];
    while (marker == 0xFF) {
      pos++;
      if (pos + 4 > bytes.length) return null;
      marker = bytes[pos + 1];
    }

    if (marker == 0xD9) return pos + 2; // EOI with no scan — degenerate but valid
    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      // SOI again or parameterless markers are not valid in the header section.
      return null;
    }
    // Only known header markers are accepted: APPn, COM, DQT, DHT, DAC,
    // SOFn, DNL, DRI, DHP, EXP, JPGn extensions excluded as invalid in
    // practice (real previews never use them).
    final bool known = (marker >= 0xC0 && marker <= 0xCF) || // SOF0-15, DHT(C4), DAC(CC)
        (marker >= 0xE0 && marker <= 0xEF) || // APPn
        marker == 0xDB || // DQT
        marker == 0xDC || // DNL
        marker == 0xDD || // DRI
        marker == 0xDE || // DHP
        marker == 0xDF || // EXP
        marker == 0xFE || // COM
        marker == 0xDA; // SOS
    if (!known) return null;

    final segLen = (bytes[pos + 2] << 8) | bytes[pos + 3];
    if (segLen < 2) return null;

    if (marker == 0xDA) {
      // SOS: entropy-coded data follows the SOS header.
      pos = pos + 2 + segLen;
      break;
    }
    pos = pos + 2 + segLen;
  }

  // Entropy-coded section: scan for EOI, honoring stuffing/restart markers.
  while (pos + 1 < bytes.length) {
    if (bytes[pos] == 0xFF) {
      final m = bytes[pos + 1];
      if (m == 0xD9) return pos + 2; // EOI
      if (m == 0x00 || m == 0xFF || (m >= 0xD0 && m <= 0xD7)) {
        pos += 2; // stuffed byte, fill byte, or restart marker
        continue;
      }
      // Another segment can technically appear (DNL); tolerate by skipping
      // its declared length when plausible, else treat as data.
      if (pos + 3 < bytes.length) {
        final segLen = (bytes[pos + 2] << 8) | bytes[pos + 3];
        if (segLen >= 2 && pos + 2 + segLen <= bytes.length) {
          pos = pos + 2 + segLen;
          continue;
        }
      }
      return null;
    }
    pos++;
  }
  return null; // truncated — no EOI
}
