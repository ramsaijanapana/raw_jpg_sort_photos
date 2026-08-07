import 'dart:io';

import 'package:image/image.dart' as image;

void main() {
  final appDirectory = File.fromUri(Platform.script).parent.parent;
  final sourceIcon = File('${appDirectory.path}/assets/icon/icon.png');
  final appIconDirectory = Directory(
    '${appDirectory.path}/ios/Runner/Assets.xcassets/AppIcon.appiconset',
  );

  final failures = <String>[];
  final icons = <File>[sourceIcon];

  if (!sourceIcon.existsSync()) {
    failures.add('${sourceIcon.path}: source icon does not exist');
  }

  if (!appIconDirectory.existsSync()) {
    failures.add(
      '${appIconDirectory.path}: iOS AppIcon directory does not exist',
    );
  } else {
    final generatedIcons =
        appIconDirectory
            .listSync(followLinks: false)
            .whereType<File>()
            .where((file) => file.path.toLowerCase().endsWith('.png'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    if (generatedIcons.isEmpty) {
      failures.add('${appIconDirectory.path}: contains no generated PNG icons');
    }
    icons.addAll(generatedIcons);
  }

  for (final icon in icons.where((file) => file.existsSync())) {
    image.Image? decoded;
    try {
      decoded = image.decodePng(icon.readAsBytesSync());
    } on Object catch (error) {
      failures.add('${icon.path}: PNG decode failed: $error');
      continue;
    }

    if (decoded == null) {
      failures.add('${icon.path}: is not a decodable PNG');
      continue;
    }

    if (icon.path == sourceIcon.path &&
        (decoded.width != 1024 || decoded.height != 1024)) {
      failures.add(
        '${icon.path}: source icon must be 1024x1024, '
        'found ${decoded.width}x${decoded.height}',
      );
    }

    var transparentPixelCount = 0;
    int? firstTransparentX;
    int? firstTransparentY;
    num? firstTransparentAlpha;
    for (final pixel in decoded) {
      if (pixel.a != 255) {
        transparentPixelCount++;
        if (firstTransparentX == null) {
          firstTransparentX = pixel.x;
          firstTransparentY = pixel.y;
          firstTransparentAlpha = pixel.a;
        }
      }
    }
    if (firstTransparentX != null) {
      failures.add(
        '${icon.path}: $transparentPixelCount pixel(s) have alpha below 255; '
        'first at ($firstTransparentX, $firstTransparentY) '
        'with alpha $firstTransparentAlpha',
      );
    }
  }

  if (failures.isNotEmpty) {
    stderr.writeln('iOS asset verification failed:');
    for (final failure in failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Verified ${icons.length} icon PNGs: source is 1024x1024 and every '
    'pixel is opaque.',
  );
}
