import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:photo_sorter/core/exporter.dart';
import 'package:photo_sorter/core/cull_session.dart';
import 'package:photo_sorter/core/models.dart';

void main() {
  late Directory src;
  late Directory dest;

  setUp(() async {
    src = await Directory.systemTemp.createTemp('exporter_src_');
    dest = await Directory.systemTemp.createTemp('exporter_dest_');
  });

  tearDown(() async {
    await src.delete(recursive: true);
    await dest.delete(recursive: true);
  });

  Future<File> createFile(String path, [String content = 'data']) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
    return f;
  }

  Future<PhotoPair> makePair({
    required String stem,
    required String rawExt,
    String? jpgExt,
  }) async {
    final rawFile = await createFile(p.join(src.path, '$stem$rawExt'), 'raw_content');
    File? jpgFile;
    if (jpgExt != null) {
      jpgFile = await createFile(p.join(src.path, '$stem$jpgExt'), 'jpg_content');
    }
    return PhotoPair(stem: stem, raw: rawFile, jpg: jpgFile);
  }

  group('exportKept', () {
    test('copies kept RAW files', () async {
      final pair = await makePair(stem: 'DSC_0001', rawExt: '.arw');
      final session = CullSession(flags: {'DSC_0001': CullFlag.keep});

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'DSC_0001.arw')).existsSync(), isTrue);
    });

    test('copies kept RAW and JPG when includeJpgs=true', () async {
      final pair = await makePair(stem: 'DSC_0002', rawExt: '.nef', jpgExt: '.jpg');
      final session = CullSession(flags: {'DSC_0002': CullFlag.keep});

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 2);
      expect(File(p.join(dest.path, 'DSC_0002.nef')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'DSC_0002.jpg')).existsSync(), isTrue);
    });

    test('respects includeJpgs=false: only copies RAW', () async {
      final pair = await makePair(stem: 'DSC_0003', rawExt: '.cr2', jpgExt: '.jpg');
      final session = CullSession(flags: {'DSC_0003': CullFlag.keep});

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'DSC_0003.cr2')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'DSC_0003.jpg')).existsSync(), isFalse);
    });

    test('skips non-keep flagged pairs', () async {
      final pair1 = await makePair(stem: 'DSC_0004', rawExt: '.arw');
      final pair2 = await makePair(stem: 'DSC_0005', rawExt: '.arw');
      final pair3 = await makePair(stem: 'DSC_0006', rawExt: '.arw');

      final session = CullSession(flags: {
        'DSC_0004': CullFlag.keep,
        'DSC_0005': CullFlag.skip,
        // DSC_0006 is undecided
      });

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair1, pair2, pair3],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(File(p.join(dest.path, 'DSC_0004.arw')).existsSync(), isTrue);
      expect(File(p.join(dest.path, 'DSC_0005.arw')).existsSync(), isFalse);
      expect(File(p.join(dest.path, 'DSC_0006.arw')).existsSync(), isFalse);
    });

    test('skips skip-flagged pairs', () async {
      final pair = await makePair(stem: 'DSC_0007', rawExt: '.nef', jpgExt: '.jpg');
      final session = CullSession(flags: {'DSC_0007': CullFlag.skip});

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 0);
    });

    test('skips undecided pairs', () async {
      final pair = await makePair(stem: 'DSC_0008', rawExt: '.arw');
      final session = CullSession(); // all undecided by default

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 0);
    });

    test('creates destination directory if needed', () async {
      final newDest = Directory(p.join(dest.path, 'subdir', 'nested'));
      final pair = await makePair(stem: 'DSC_0009', rawExt: '.arw');
      final session = CullSession(flags: {'DSC_0009': CullFlag.keep});

      final result = await exportKept(
        source: src,
        destination: newDest,
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.copied, 1);
      expect(newDest.existsSync(), isTrue);
    });

    test('returned outputPath matches destination', () async {
      final pair = await makePair(stem: 'DSC_0010', rawExt: '.arw');
      final session = CullSession(flags: {'DSC_0010': CullFlag.keep});

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      expect(result.outputPath, dest.path);
    });

    test('overwrites existing file (matches Python shutil.copy2 behavior)', () async {
      final pair = await makePair(stem: 'DSC_0011', rawExt: '.arw');
      // Pre-create file at destination with different content
      await createFile(p.join(dest.path, 'DSC_0011.arw'), 'old_content');

      final session = CullSession(flags: {'DSC_0011': CullFlag.keep});
      await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: false,
      );

      // Should be overwritten with new content
      expect(
        File(p.join(dest.path, 'DSC_0011.arw')).readAsStringSync(),
        'raw_content',
      );
    });

    test('handles raw-only pair with includeJpgs=true gracefully', () async {
      final pair = await makePair(stem: 'DSC_0012', rawExt: '.arw'); // no jpg
      final session = CullSession(flags: {'DSC_0012': CullFlag.keep});

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [pair],
        session: session,
        includeJpgs: true,
      );

      // Only RAW copied since jpg is null
      expect(result.copied, 1);
    });

    test('empty pairs list returns zero copied', () async {
      final session = CullSession();

      final result = await exportKept(
        source: src,
        destination: dest,
        pairs: [],
        session: session,
        includeJpgs: true,
      );

      expect(result.copied, 0);
    });
  });
}
