import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:path/path.dart' as p;

class IosAssetVerificationResult {
  const IosAssetVerificationResult({
    required this.failures,
    required this.declaredRenditionCount,
    required this.catalogPngCount,
  });

  final List<String> failures;
  final int declaredRenditionCount;
  final int catalogPngCount;
}

typedef _AppIconSlot = ({String idiom, String size, String scale});

const _expectedAppIconSlots = <_AppIconSlot>{
  (idiom: 'iphone', size: '20x20', scale: '2x'),
  (idiom: 'iphone', size: '20x20', scale: '3x'),
  (idiom: 'iphone', size: '29x29', scale: '1x'),
  (idiom: 'iphone', size: '29x29', scale: '2x'),
  (idiom: 'iphone', size: '29x29', scale: '3x'),
  (idiom: 'iphone', size: '40x40', scale: '2x'),
  (idiom: 'iphone', size: '40x40', scale: '3x'),
  (idiom: 'iphone', size: '57x57', scale: '1x'),
  (idiom: 'iphone', size: '57x57', scale: '2x'),
  (idiom: 'iphone', size: '60x60', scale: '2x'),
  (idiom: 'iphone', size: '60x60', scale: '3x'),
  (idiom: 'ipad', size: '20x20', scale: '1x'),
  (idiom: 'ipad', size: '20x20', scale: '2x'),
  (idiom: 'ipad', size: '29x29', scale: '1x'),
  (idiom: 'ipad', size: '29x29', scale: '2x'),
  (idiom: 'ipad', size: '40x40', scale: '1x'),
  (idiom: 'ipad', size: '40x40', scale: '2x'),
  (idiom: 'ipad', size: '50x50', scale: '1x'),
  (idiom: 'ipad', size: '50x50', scale: '2x'),
  (idiom: 'ipad', size: '72x72', scale: '1x'),
  (idiom: 'ipad', size: '72x72', scale: '2x'),
  (idiom: 'ipad', size: '76x76', scale: '1x'),
  (idiom: 'ipad', size: '76x76', scale: '2x'),
  (idiom: 'ipad', size: '83.5x83.5', scale: '2x'),
  (idiom: 'ios-marketing', size: '1024x1024', scale: '1x'),
};

IosAssetVerificationResult verifyIosAssets(Directory appDirectory) {
  final failures = <String>[];
  final sourceIcon = File(
    p.join(appDirectory.path, 'assets', 'icon', 'icon_ios.png'),
  );
  final appIconDirectory = Directory(
    p.join(
      appDirectory.path,
      'ios',
      'Runner',
      'Assets.xcassets',
      'AppIcon.appiconset',
    ),
  );
  final contentsFile = File(p.join(appIconDirectory.path, 'Contents.json'));

  final sourceImage = _decodePng(sourceIcon, failures, label: 'iOS source');
  if (sourceImage != null) {
    if (sourceImage.width != 1024 || sourceImage.height != 1024) {
      failures.add(
        '${sourceIcon.path}: iOS source must be 1024x1024 pixels, '
        'found ${sourceImage.width}x${sourceImage.height}',
      );
    }
    _rejectAlphaChannel(sourceIcon, sourceImage, failures);
  }

  if (!appIconDirectory.existsSync()) {
    failures.add(
      '${appIconDirectory.path}: iOS AppIcon directory does not exist',
    );
    return IosAssetVerificationResult(
      failures: failures,
      declaredRenditionCount: 0,
      catalogPngCount: 0,
    );
  }

  final catalogPngs =
      appIconDirectory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((file) => p.extension(file.path).toLowerCase() == '.png')
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
  final actualPngsByName = <String, File>{
    for (final file in catalogPngs) p.basename(file.path): file,
  };

  final renditions = _readRenditions(contentsFile, failures);
  _validateExpectedSlots(contentsFile, renditions, failures);
  final declaredFilenames =
      renditions
          .map((rendition) => rendition.filename)
          .whereType<String>()
          .toSet()
          .toList()
        ..sort();
  final declaredFilenameSet = declaredFilenames.toSet();

  for (final filename in declaredFilenames) {
    if (!actualPngsByName.containsKey(filename)) {
      failures.add(
        '${p.join(appIconDirectory.path, filename)}: declared PNG does not exist',
      );
    }
  }
  for (final filename in actualPngsByName.keys) {
    if (!declaredFilenameSet.contains(filename)) {
      failures.add(
        '${p.join(appIconDirectory.path, filename)}: PNG is not declared in '
        'Contents.json',
      );
    }
  }

  final decodedCatalogPngs = <String, image.Image>{};
  for (final filename in declaredFilenames) {
    final file = actualPngsByName[filename];
    if (file == null) {
      continue;
    }
    final decoded = _decodePng(file, failures, label: 'declared catalog PNG');
    if (decoded != null) {
      decodedCatalogPngs[filename] = decoded;
      _rejectAlphaChannel(file, decoded, failures);
    }
  }

  for (final rendition in renditions) {
    final filename = rendition.filename;
    final expectedSize = rendition.expectedPixelSize;
    if (filename == null || expectedSize == null) {
      continue;
    }
    final decoded = decodedCatalogPngs[filename];
    if (decoded == null) {
      continue;
    }
    if (decoded.width != expectedSize.width ||
        decoded.height != expectedSize.height) {
      failures.add(
        '${p.join(appIconDirectory.path, filename)}: rendition '
        '${rendition.index} expected ${expectedSize.width}x${expectedSize.height} '
        'pixels, found ${decoded.width}x${decoded.height}',
      );
    }
  }

  final marketingRenditions = renditions
      .where((rendition) => rendition.isRequiredMarketingRendition)
      .toList();
  if (marketingRenditions.length != 1) {
    failures.add(
      '${contentsFile.path}: expected exactly one declared ios-marketing '
      '1024x1024@1x rendition with a filename, found '
      '${marketingRenditions.length}',
    );
  } else if (sourceImage != null) {
    final marketingFilename = marketingRenditions.single.filename!;
    final marketingImage = decodedCatalogPngs[marketingFilename];
    if (marketingImage != null && !_pixelsMatch(sourceImage, marketingImage)) {
      failures.add(
        '${p.join(appIconDirectory.path, marketingFilename)}: marketing icon '
        'does not match the opaque iOS source pixel-for-pixel',
      );
    }
  }

  return IosAssetVerificationResult(
    failures: failures,
    declaredRenditionCount: renditions.length,
    catalogPngCount: catalogPngs.length,
  );
}

void main() {
  final appDirectory = File.fromUri(Platform.script).parent.parent;
  final result = verifyIosAssets(appDirectory);

  if (result.failures.isNotEmpty) {
    stderr.writeln('iOS asset verification failed:');
    for (final failure in result.failures) {
      stderr.writeln('- $failure');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Verified ${result.declaredRenditionCount} declared iOS icon renditions '
    'across ${result.catalogPngCount} catalog PNGs: dimensions match '
    'Contents.json, every PNG is RGB without an alpha channel, and the '
    '1024x1024 marketing icon matches the opaque iOS source.',
  );
}

List<_DeclaredRendition> _readRenditions(
  File contentsFile,
  List<String> failures,
) {
  if (!contentsFile.existsSync()) {
    failures.add('${contentsFile.path}: asset catalog manifest does not exist');
    return const [];
  }

  Object? manifest;
  try {
    manifest = jsonDecode(contentsFile.readAsStringSync());
  } on Object catch (error) {
    failures.add('${contentsFile.path}: JSON decode failed: $error');
    return const [];
  }
  if (manifest is! Map<String, dynamic>) {
    failures.add(
      '${contentsFile.path}: top-level JSON value must be an object',
    );
    return const [];
  }

  final images = manifest['images'];
  if (images is! List) {
    failures.add('${contentsFile.path}: "images" must be an array');
    return const [];
  }

  final renditions = <_DeclaredRendition>[];
  for (var index = 0; index < images.length; index++) {
    final rawRendition = images[index];
    if (rawRendition is! Map) {
      failures.add(
        '${contentsFile.path}: rendition $index must be a JSON object',
      );
      continue;
    }

    final filename = rawRendition['filename'];
    final size = rawRendition['size'];
    final scale = rawRendition['scale'];
    final idiom = rawRendition['idiom'];
    final validFilename = filename is String && filename.isNotEmpty
        ? filename
        : null;
    if (validFilename == null) {
      failures.add(
        '${contentsFile.path}: rendition $index does not declare a filename',
      );
    } else if (p.basename(validFilename) != validFilename) {
      failures.add(
        '${contentsFile.path}: rendition $index filename must not contain a '
        'directory: $validFilename',
      );
    }

    final validIdiom = idiom is String && idiom.isNotEmpty ? idiom : null;
    if (validIdiom == null) {
      failures.add(
        '${contentsFile.path}: rendition $index has invalid idiom: $idiom',
      );
    }

    final expectedPixelSize = _parseExpectedPixelSize(size, scale);
    if (expectedPixelSize == null) {
      failures.add(
        '${contentsFile.path}: rendition $index has invalid size/scale '
        'values: size=$size, scale=$scale',
      );
    }

    renditions.add(
      _DeclaredRendition(
        index: index,
        filename: validFilename,
        idiom: validIdiom,
        size: size is String ? size : null,
        scale: scale is String ? scale : null,
        expectedPixelSize: expectedPixelSize,
      ),
    );
  }
  renditions.sort(_compareDeclaredRenditions);
  return renditions;
}

void _validateExpectedSlots(
  File contentsFile,
  List<_DeclaredRendition> renditions,
  List<String> failures,
) {
  final counts = <_AppIconSlot, int>{};
  for (final rendition in renditions) {
    final slot = rendition.slot;
    if (slot != null) {
      counts.update(slot, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  final expectedSlots = _expectedAppIconSlots.toList()
    ..sort(_compareAppIconSlots);
  for (final slot in expectedSlots) {
    if (!counts.containsKey(slot)) {
      failures.add(
        '${contentsFile.path}: missing required AppIcon slot '
        '${_describeAppIconSlot(slot)}',
      );
    }
  }

  final declaredSlots = counts.keys.toList()..sort(_compareAppIconSlots);
  for (final slot in declaredSlots) {
    final count = counts[slot]!;
    if (count > 1) {
      failures.add(
        '${contentsFile.path}: duplicate AppIcon slot '
        '${_describeAppIconSlot(slot)} is declared $count times',
      );
    }
    if (!_expectedAppIconSlots.contains(slot)) {
      failures.add(
        '${contentsFile.path}: unexpected AppIcon slot '
        '${_describeAppIconSlot(slot)}',
      );
    }
  }
}

int _compareDeclaredRenditions(_DeclaredRendition a, _DeclaredRendition b) {
  final aSlot = a.slot;
  final bSlot = b.slot;
  if (aSlot != null && bSlot != null) {
    final slotComparison = _compareAppIconSlots(aSlot, bSlot);
    if (slotComparison != 0) {
      return slotComparison;
    }
  } else if (aSlot != null) {
    return -1;
  } else if (bSlot != null) {
    return 1;
  }

  final filenameComparison = (a.filename ?? '').compareTo(b.filename ?? '');
  return filenameComparison != 0
      ? filenameComparison
      : a.index.compareTo(b.index);
}

int _compareAppIconSlots(_AppIconSlot a, _AppIconSlot b) {
  final idiomComparison = a.idiom.compareTo(b.idiom);
  if (idiomComparison != 0) {
    return idiomComparison;
  }
  final sizeComparison = a.size.compareTo(b.size);
  return sizeComparison != 0 ? sizeComparison : a.scale.compareTo(b.scale);
}

String _describeAppIconSlot(_AppIconSlot slot) =>
    '${slot.idiom} ${slot.size}@${slot.scale}';

_PixelSize? _parseExpectedPixelSize(Object? size, Object? scale) {
  if (size is! String || scale is! String) {
    return null;
  }
  final sizeMatch = RegExp(
    r'^(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)$',
  ).firstMatch(size);
  final scaleMatch = RegExp(r'^(\d+(?:\.\d+)?)x$').firstMatch(scale);
  if (sizeMatch == null || scaleMatch == null) {
    return null;
  }

  final width = double.parse(sizeMatch.group(1)!);
  final height = double.parse(sizeMatch.group(2)!);
  final multiplier = double.parse(scaleMatch.group(1)!);
  final scaledWidth = width * multiplier;
  final scaledHeight = height * multiplier;
  if (scaledWidth <= 0 ||
      scaledHeight <= 0 ||
      scaledWidth != scaledWidth.roundToDouble() ||
      scaledHeight != scaledHeight.roundToDouble()) {
    return null;
  }
  return _PixelSize(scaledWidth.round(), scaledHeight.round());
}

image.Image? _decodePng(
  File file,
  List<String> failures, {
  required String label,
}) {
  if (!file.existsSync()) {
    failures.add('${file.path}: $label does not exist');
    return null;
  }

  image.Image? decoded;
  try {
    decoded = image.decodePng(file.readAsBytesSync());
  } on Object catch (error) {
    failures.add('${file.path}: PNG decode failed: $error');
    return null;
  }
  if (decoded == null) {
    failures.add('${file.path}: is not a decodable PNG');
  }
  return decoded;
}

void _rejectAlphaChannel(
  File file,
  image.Image decoded,
  List<String> failures,
) {
  if (decoded.hasAlpha) {
    failures.add(
      '${file.path}: contains an alpha channel (${decoded.numChannels} '
      'decoded channels); iOS App Store icons must be RGB',
    );
  }
}

bool _pixelsMatch(image.Image first, image.Image second) {
  if (first.width != second.width || first.height != second.height) {
    return false;
  }
  final firstRgb = first.getBytes(order: image.ChannelOrder.rgb);
  final secondRgb = second.getBytes(order: image.ChannelOrder.rgb);
  return _bytesMatch(firstRgb, secondRgb);
}

bool _bytesMatch(Uint8List first, Uint8List second) {
  if (first.length != second.length) {
    return false;
  }
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) {
      return false;
    }
  }
  return true;
}

class _DeclaredRendition {
  const _DeclaredRendition({
    required this.index,
    required this.filename,
    required this.idiom,
    required this.size,
    required this.scale,
    required this.expectedPixelSize,
  });

  final int index;
  final String? filename;
  final String? idiom;
  final String? size;
  final String? scale;
  final _PixelSize? expectedPixelSize;

  _AppIconSlot? get slot => idiom == null || size == null || scale == null
      ? null
      : (idiom: idiom!, size: size!, scale: scale!);

  bool get isRequiredMarketingRendition =>
      idiom == 'ios-marketing' &&
      size == '1024x1024' &&
      scale == '1x' &&
      filename != null;
}

class _PixelSize {
  const _PixelSize(this.width, this.height);

  final int width;
  final int height;
}
