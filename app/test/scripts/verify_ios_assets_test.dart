import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;

import '../../scripts/verify_ios_assets.dart' as verifier;

void main() {
  late Directory appDirectory;
  late File contentsFile;
  late File sourceIcon;
  late Directory appIconDirectory;

  setUp(() async {
    appDirectory = await Directory.systemTemp.createTemp(
      'ios_asset_verifier_test_',
    );
    sourceIcon = File(p.join(appDirectory.path, 'assets/icon/icon_ios.png'));
    appIconDirectory = Directory(
      p.join(
        appDirectory.path,
        'ios/Runner/Assets.xcassets/AppIcon.appiconset',
      ),
    );
    contentsFile = File(p.join(appIconDirectory.path, 'Contents.json'));

    await _writePng(sourceIcon, width: 1024, height: 1024);
    for (final rendition in _validImages) {
      final filename = rendition['filename']! as String;
      final file = File(p.join(appIconDirectory.path, filename));
      if (file.existsSync()) {
        continue;
      }
      if (rendition['idiom'] == 'ios-marketing') {
        await file.writeAsBytes(await sourceIcon.readAsBytes());
      } else {
        final dimensions = _pixelDimensions(
          rendition['size']! as String,
          rendition['scale']! as String,
        );
        await _writePng(
          file,
          width: dimensions.width,
          height: dimensions.height,
        );
      }
    }
    await _writeContents(contentsFile, _validImages);
  });

  tearDown(() async {
    await appDirectory.delete(recursive: true);
  });

  test('accepts a complete opaque catalog whose marketing icon matches', () {
    final result = verifier.verifyIosAssets(appDirectory);

    expect(result.failures, isEmpty);
    expect(result.declaredRenditionCount, 25);
    expect(result.catalogPngCount, 21);
  });

  test('requires one declared 1024x1024 at 1x marketing rendition', () async {
    await _writeContents(
      contentsFile,
      _validImages
          .where((rendition) => rendition['idiom'] != 'ios-marketing')
          .toList(),
    );
    await File(
      p.join(appIconDirectory.path, 'Icon-App-1024x1024@1x.png'),
    ).delete();

    final result = verifier.verifyIosAssets(appDirectory);

    expect(
      result.failures,
      contains(contains('ios-marketing 1024x1024@1x rendition')),
    );
  });

  test('requires every rendition to declare an existing filename', () async {
    final images = _copyValidImages();
    images[0] = <String, Object>{
      'size': '20x20',
      'idiom': 'iphone',
      'scale': '2x',
    };
    await _writeContents(contentsFile, images);

    final result = verifier.verifyIosAssets(appDirectory);

    expect(result.failures, contains(contains('does not declare a filename')));
  });

  test('rejects missing declared PNGs and unexpected catalog PNGs', () async {
    await File(p.join(appIconDirectory.path, 'Icon-App-20x20@2x.png')).delete();
    await _writePng(
      File(p.join(appIconDirectory.path, 'Unexpected.png')),
      width: 40,
      height: 40,
    );

    final result = verifier.verifyIosAssets(appDirectory);

    expect(
      result.failures,
      contains(contains('Icon-App-20x20@2x.png: declared PNG does not exist')),
    );
    expect(
      result.failures,
      contains(contains('Unexpected.png: PNG is not declared')),
    );
  });

  test('rejects removal of an ordinary declaration and its PNG', () async {
    final images = _copyValidImages()
      ..removeWhere(
        (rendition) =>
            rendition['idiom'] == 'iphone' &&
            rendition['size'] == '60x60' &&
            rendition['scale'] == '3x',
      );
    await _writeContents(contentsFile, images);
    await File(p.join(appIconDirectory.path, 'Icon-App-60x60@3x.png')).delete();

    final result = verifier.verifyIosAssets(appDirectory);

    expect(
      result.failures,
      contains(contains('missing required AppIcon slot iphone 60x60@3x')),
    );
  });

  test('rejects a duplicated non-marketing slot', () async {
    final images = _copyValidImages()
      ..add(Map<String, Object>.from(_validImages.first));
    await _writeContents(contentsFile, images);

    final result = verifier.verifyIosAssets(appDirectory);

    expect(
      result.failures,
      contains(contains('duplicate AppIcon slot iphone 20x20@2x')),
    );
  });

  test('rejects an unexpected non-marketing slot', () async {
    final images = _copyValidImages()
      ..add(<String, Object>{
        'size': '16x16',
        'idiom': 'iphone',
        'filename': 'Unexpected-Slot.png',
        'scale': '1x',
      });
    await _writeContents(contentsFile, images);
    await _writePng(
      File(p.join(appIconDirectory.path, 'Unexpected-Slot.png')),
      width: 16,
      height: 16,
    );

    final result = verifier.verifyIosAssets(appDirectory);

    expect(
      result.failures,
      contains(contains('unexpected AppIcon slot iphone 16x16@1x')),
    );
  });

  test(
    'validates each rendition pixel dimensions from size and scale',
    () async {
      await _writePng(
        File(p.join(appIconDirectory.path, 'Icon-App-20x20@2x.png')),
        width: 39,
        height: 40,
      );

      final result = verifier.verifyIosAssets(appDirectory);

      expect(
        result.failures,
        contains(contains('expected 40x40 pixels, found 39x40')),
      );
    },
  );

  test('rejects an alpha channel even when every alpha value is 255', () async {
    await _writePng(
      File(p.join(appIconDirectory.path, 'Icon-App-20x20@2x.png')),
      width: 40,
      height: 40,
      withAlphaChannel: true,
    );

    final result = verifier.verifyIosAssets(appDirectory);

    expect(result.failures, contains(contains('contains an alpha channel')));
  });

  test(
    'requires the marketing rendition to match the opaque iOS source',
    () async {
      await _writePng(
        File(p.join(appIconDirectory.path, 'Icon-App-1024x1024@1x.png')),
        width: 1024,
        height: 1024,
        red: 99,
      );

      final result = verifier.verifyIosAssets(appDirectory);

      expect(
        result.failures,
        contains(
          contains('does not match the opaque iOS source pixel-for-pixel'),
        ),
      );
    },
  );
}

const _validImages = <Map<String, Object>>[
  {
    'size': '20x20',
    'idiom': 'iphone',
    'filename': 'Icon-App-20x20@2x.png',
    'scale': '2x',
  },
  {
    'size': '20x20',
    'idiom': 'iphone',
    'filename': 'Icon-App-20x20@3x.png',
    'scale': '3x',
  },
  {
    'size': '29x29',
    'idiom': 'iphone',
    'filename': 'Icon-App-29x29@1x.png',
    'scale': '1x',
  },
  {
    'size': '29x29',
    'idiom': 'iphone',
    'filename': 'Icon-App-29x29@2x.png',
    'scale': '2x',
  },
  {
    'size': '29x29',
    'idiom': 'iphone',
    'filename': 'Icon-App-29x29@3x.png',
    'scale': '3x',
  },
  {
    'size': '40x40',
    'idiom': 'iphone',
    'filename': 'Icon-App-40x40@2x.png',
    'scale': '2x',
  },
  {
    'size': '40x40',
    'idiom': 'iphone',
    'filename': 'Icon-App-40x40@3x.png',
    'scale': '3x',
  },
  {
    'size': '57x57',
    'idiom': 'iphone',
    'filename': 'Icon-App-57x57@1x.png',
    'scale': '1x',
  },
  {
    'size': '57x57',
    'idiom': 'iphone',
    'filename': 'Icon-App-57x57@2x.png',
    'scale': '2x',
  },
  {
    'size': '60x60',
    'idiom': 'iphone',
    'filename': 'Icon-App-60x60@2x.png',
    'scale': '2x',
  },
  {
    'size': '60x60',
    'idiom': 'iphone',
    'filename': 'Icon-App-60x60@3x.png',
    'scale': '3x',
  },
  {
    'size': '20x20',
    'idiom': 'ipad',
    'filename': 'Icon-App-20x20@1x.png',
    'scale': '1x',
  },
  {
    'size': '20x20',
    'idiom': 'ipad',
    'filename': 'Icon-App-20x20@2x.png',
    'scale': '2x',
  },
  {
    'size': '29x29',
    'idiom': 'ipad',
    'filename': 'Icon-App-29x29@1x.png',
    'scale': '1x',
  },
  {
    'size': '29x29',
    'idiom': 'ipad',
    'filename': 'Icon-App-29x29@2x.png',
    'scale': '2x',
  },
  {
    'size': '40x40',
    'idiom': 'ipad',
    'filename': 'Icon-App-40x40@1x.png',
    'scale': '1x',
  },
  {
    'size': '40x40',
    'idiom': 'ipad',
    'filename': 'Icon-App-40x40@2x.png',
    'scale': '2x',
  },
  {
    'size': '50x50',
    'idiom': 'ipad',
    'filename': 'Icon-App-50x50@1x.png',
    'scale': '1x',
  },
  {
    'size': '50x50',
    'idiom': 'ipad',
    'filename': 'Icon-App-50x50@2x.png',
    'scale': '2x',
  },
  {
    'size': '72x72',
    'idiom': 'ipad',
    'filename': 'Icon-App-72x72@1x.png',
    'scale': '1x',
  },
  {
    'size': '72x72',
    'idiom': 'ipad',
    'filename': 'Icon-App-72x72@2x.png',
    'scale': '2x',
  },
  {
    'size': '76x76',
    'idiom': 'ipad',
    'filename': 'Icon-App-76x76@1x.png',
    'scale': '1x',
  },
  {
    'size': '76x76',
    'idiom': 'ipad',
    'filename': 'Icon-App-76x76@2x.png',
    'scale': '2x',
  },
  {
    'size': '83.5x83.5',
    'idiom': 'ipad',
    'filename': 'Icon-App-83.5x83.5@2x.png',
    'scale': '2x',
  },
  {
    'size': '1024x1024',
    'idiom': 'ios-marketing',
    'filename': 'Icon-App-1024x1024@1x.png',
    'scale': '1x',
  },
];

List<Map<String, Object>> _copyValidImages() =>
    _validImages.map(Map<String, Object>.from).toList();

({int width, int height}) _pixelDimensions(String size, String scale) {
  final dimensions = size.split('x').map(double.parse).toList();
  final multiplier = double.parse(scale.substring(0, scale.length - 1));
  return (
    width: (dimensions[0] * multiplier).round(),
    height: (dimensions[1] * multiplier).round(),
  );
}

Future<void> _writeContents(
  File contentsFile,
  List<Map<String, Object>> images,
) async {
  await contentsFile.parent.create(recursive: true);
  await contentsFile.writeAsString(
    jsonEncode({
      'images': images,
      'info': {'version': 1, 'author': 'xcode'},
    }),
  );
}

Future<void> _writePng(
  File file, {
  required int width,
  required int height,
  bool withAlphaChannel = false,
  int red = 33,
}) async {
  await file.parent.create(recursive: true);
  final png = image.Image(
    width: width,
    height: height,
    numChannels: withAlphaChannel ? 4 : 3,
  );
  image.fill(
    png,
    color: withAlphaChannel
        ? image.ColorRgba8(red, 37, 45, 255)
        : image.ColorRgb8(red, 37, 45),
  );
  await file.writeAsBytes(image.encodePng(png));
}
