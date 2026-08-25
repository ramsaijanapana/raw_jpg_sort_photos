import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/services/local_path_classifier.dart';

/// Host-deterministic conversion used as the expected value for `file:` URLs.
String? hostFileUrlPath(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.isScheme('file')) return null;
  try {
    final path = uri.toFilePath();
    if (path.isEmpty || path.contains('\u0000')) return null;
    return path;
  } on UnsupportedError {
    return null;
  }
}

void main() {
  group('classifyLocalDirectoryPath — Windows drive letters', () {
    test('accepts C:\\Photos and does not treat C as a URI scheme', () {
      const raw = r'C:\Photos';
      // Dart's Uri parser is the trap this classifier must not follow.
      expect(Uri.tryParse(raw)?.hasScheme, isTrue);
      expect(Uri.tryParse(raw)?.scheme.toLowerCase(), 'c');
      expect(classifyLocalDirectoryPath(raw), raw);
    });

    test('accepts C:/Photos (forward slashes)', () {
      const raw = 'C:/Photos';
      expect(Uri.tryParse(raw)?.hasScheme, isTrue);
      expect(classifyLocalDirectoryPath(raw), raw);
    });

    test('accepts lowercase drive and nested folders', () {
      expect(classifyLocalDirectoryPath(r'd:\RAW\Shoot'), r'd:\RAW\Shoot');
      expect(classifyLocalDirectoryPath('E:/Photos/JPG'), 'E:/Photos/JPG');
    });

    test('accepts a drive root', () {
      expect(classifyLocalDirectoryPath(r'C:\'), r'C:\');
      expect(classifyLocalDirectoryPath('C:/'), 'C:/');
    });

    test('rejects a single-letter scheme that is not a drive path', () {
      expect(classifyLocalDirectoryPath('c:Photos'), isNull);
    });
  });

  group('classifyLocalDirectoryPath — POSIX and UNC', () {
    test('accepts a normal POSIX path', () {
      expect(
        classifyLocalDirectoryPath('/Users/dev/Pictures/Shoot'),
        '/Users/dev/Pictures/Shoot',
      );
    });

    test('accepts a POSIX path that contains % (must not Uri-parse-fail)', () {
      expect(
        classifyLocalDirectoryPath('/tmp/100%done'),
        '/tmp/100%done',
      );
    });

    test('accepts UNC paths', () {
      expect(
        classifyLocalDirectoryPath(r'\\server\share\Photos'),
        r'\\server\share\Photos',
      );
      expect(
        classifyLocalDirectoryPath(r'\\?\C:\Photos'),
        r'\\?\C:\Photos',
      );
    });

    test('accepts a relative local path', () {
      expect(classifyLocalDirectoryPath('Photos'), 'Photos');
    });
  });

  group('classifyLocalDirectoryPath — file URLs', () {
    test('accepts file:/// POSIX URLs only as a converted local path', () {
      const raw = 'file:///tmp/photo-sorter-host-path';
      final expected = hostFileUrlPath(raw);
      expect(expected, isNotNull);
      expect(classifyLocalDirectoryPath(raw), expected);
      expect(classifyLocalDirectoryPath(raw), isNot(raw));
    });

    test('accepts file:///C:/Photos when convertible on this host', () {
      const raw = 'file:///C:/Photos';
      expect(classifyLocalDirectoryPath(raw), hostFileUrlPath(raw));
    });

    test('file URL with a non-local host follows this host\'s toFilePath', () {
      const raw = 'file://remote-host/share/photos';
      expect(classifyLocalDirectoryPath(raw), hostFileUrlPath(raw));
    });

    test('accepts file://localhost URLs when convertible on this host', () {
      const raw = 'file://localhost/tmp/photos';
      expect(classifyLocalDirectoryPath(raw), hostFileUrlPath(raw));
    });
  });

  group('classifyLocalDirectoryPath — rejected schemes and malformed', () {
    test('rejects Android content URIs', () {
      expect(
        classifyLocalDirectoryPath(
          'content://com.android.externalstorage.documents/tree/primary%3APhotos',
        ),
        isNull,
      );
    });

    test('rejects http and https URLs', () {
      expect(classifyLocalDirectoryPath('http://example.com/photos'), isNull);
      expect(
        classifyLocalDirectoryPath('https://example.com/photos'),
        isNull,
      );
    });

    test('rejects other non-file URI schemes', () {
      expect(classifyLocalDirectoryPath('ftp://server/photos'), isNull);
      expect(classifyLocalDirectoryPath('smb://server/photos'), isNull);
    });

    test('rejects empty and NUL-containing values', () {
      expect(classifyLocalDirectoryPath(''), isNull);
      expect(classifyLocalDirectoryPath('/tmp/\u0000photos'), isNull);
      expect(classifyLocalDirectoryPath('\u0000C:\\Photos'), isNull);
    });

    test('rejects a malformed or non-convertible file URL', () {
      expect(classifyLocalDirectoryPath('file:///tmp/%zz'), isNull);
      expect(classifyLocalDirectoryPath('file:///tmp/photos?x=1'), isNull);
      expect(classifyLocalDirectoryPath('file:///tmp/photos#frag'), isNull);
    });
  });
}
