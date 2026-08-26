import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  File manifest(String relativeFromApp) {
    final fromApp = File(relativeFromApp);
    if (fromApp.existsSync()) return fromApp;
    return File(p.join('app', relativeFromApp));
  }

  const paths = [
    'android/app/src/main/AndroidManifest.xml',
    'android/app/src/debug/AndroidManifest.xml',
    'android/app/src/profile/AndroidManifest.xml',
  ];

  test(
    'main debug and profile manifests forbid broad storage permissions',
    () {
      for (final relative in paths) {
        final text = manifest(relative).readAsStringSync();
        expect(text.contains('MANAGE_EXTERNAL_STORAGE'), isFalse);
        expect(text.contains('READ_MEDIA_'), isFalse);
        expect(text.contains('READ_EXTERNAL_STORAGE'), isFalse);
        expect(text.contains('MANAGE_DOCUMENTS'), isFalse);
      }
    },
  );

  test('debug and profile INTERNET remains', () {
    for (final relative in [
      'android/app/src/debug/AndroidManifest.xml',
      'android/app/src/profile/AndroidManifest.xml',
    ]) {
      final text = manifest(relative).readAsStringSync();
      expect(text.contains('android.permission.INTERNET'), isTrue);
    }
  });
}
