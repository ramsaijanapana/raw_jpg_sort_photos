import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS release links only the document picker used by Photo Sorter', () {
    final pickerService = File('lib/services/file_pick_service.dart').readAsStringSync();
    expect(pickerService, contains('FilePicker.getDirectoryPath'));
    expect(pickerService, isNot(contains('FilePicker.pickFiles')));

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('enable-swift-package-manager: false'));

    final podfile = File('ios/Podfile');
    expect(podfile.existsSync(), isTrue);
    if (podfile.existsSync()) {
      final pods = podfile.readAsStringSync();
      expect(pods, contains('Pod::PICKER_MEDIA = false'));
      expect(pods, contains('Pod::PICKER_AUDIO = false'));
    }

    final podLock = File('ios/Podfile.lock');
    expect(podLock.existsSync(), isTrue);
    if (podLock.existsSync()) {
      final resolvedPods = podLock.readAsStringSync();
      expect(resolvedPods, isNot(contains('DKImagePickerController')));
      expect(resolvedPods, isNot(contains('DKCamera')));
    }

    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(project, isNot(contains('FlutterGeneratedPluginSwiftPackage')));

    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, isNot(contains('NSCameraUsageDescription')));
    expect(plist, isNot(contains('NSPhotoLibraryUsageDescription')));
    expect(plist, isNot(contains('NSLocationWhenInUseUsageDescription')));
  });
}
