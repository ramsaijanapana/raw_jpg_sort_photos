import 'package:path/path.dart' as p;

const Set<String> rawExtensions = {
  '.arw',
  '.cr2',
  '.cr3',
  '.nef',
  '.raf',
  '.orf',
  '.dng',
  '.rw2',
  '.pef',
  '.srw',
};

const Set<String> jpgExtensions = {
  '.jpg',
  '.jpeg',
};

/// Returns true if [filePath] has a RAW extension (case-insensitive).
bool isRaw(String filePath) =>
    rawExtensions.contains(p.extension(filePath).toLowerCase());

/// Returns true if [filePath] has a JPG/JPEG extension (case-insensitive).
bool isJpg(String filePath) =>
    jpgExtensions.contains(p.extension(filePath).toLowerCase());
