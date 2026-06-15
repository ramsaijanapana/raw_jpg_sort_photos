import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_sorter/state/cull_controller.dart';

void main() {
  group('LruCache (byte-budget)', () {
    int sizeOf(Uint8List? bytes) => bytes?.lengthInBytes ?? 16;

    Uint8List blob(int n) => Uint8List(n);

    test('evicts oldest entries when the byte budget is exceeded', () {
      // Budget of 250 bytes; each blob is 100 bytes.
      final lru = LruCache<String, Uint8List?>(250, sizeOf);

      lru.put('a', blob(100));
      lru.put('b', blob(100));
      expect(lru.containsKey('a'), isTrue);
      expect(lru.containsKey('b'), isTrue);
      expect(lru.totalBytes, 200);

      // Third insertion pushes total to 300 > 250 → oldest ('a') is evicted.
      lru.put('c', blob(100));
      expect(lru.containsKey('a'), isFalse);
      expect(lru.containsKey('b'), isTrue);
      expect(lru.containsKey('c'), isTrue);
      expect(lru.totalBytes, 200);
    });

    test('get marks an entry most-recently-used (LRU ordering)', () {
      final lru = LruCache<String, Uint8List?>(250, sizeOf);
      lru.put('a', blob(100));
      lru.put('b', blob(100));

      // Touch 'a' so it becomes most-recently-used.
      lru.get('a');

      // Inserting 'c' should now evict 'b' (the oldest), not 'a'.
      lru.put('c', blob(100));
      expect(lru.containsKey('a'), isTrue);
      expect(lru.containsKey('b'), isFalse);
      expect(lru.containsKey('c'), isTrue);
    });

    test('a cached null is remembered (distinct from absent)', () {
      final lru = LruCache<String, Uint8List?>(250, sizeOf);

      lru.put('none', null);
      expect(lru.containsKey('none'), isTrue, reason: 'null must be cached');
      // get() returns LruEntry<V>? wrapping the stored value; the value is null.
      expect(lru.get('none')!.value, isNull);
      // The null entry occupies the small constant cost (16).
      expect(lru.totalBytes, 16);

      // A key never inserted is genuinely absent.
      expect(lru.containsKey('missing'), isFalse);
    });

    test('cached null survives until evicted (no recompute signal)', () {
      // Small budget so we can observe that the null stays put while it fits.
      final lru = LruCache<String, Uint8List?>(100, sizeOf);
      lru.put('none', null);
      lru.put('none2', null);
      expect(lru.containsKey('none'), isTrue);
      expect(lru.containsKey('none2'), isTrue);
      expect(lru.totalBytes, 32);
    });

    test('inserting an oversized entry does not break the cache', () {
      final lru = LruCache<String, Uint8List?>(100, sizeOf);

      lru.put('small', blob(50));
      // 500 bytes >> 100 byte budget. Should be kept (so a get hits) and all
      // other entries evicted, without throwing or looping forever.
      lru.put('huge', blob(500));

      expect(lru.containsKey('huge'), isTrue);
      expect(lru.get('huge')!.value!.length, 500);
      expect(lru.containsKey('small'), isFalse);
      // Total reflects only the oversized survivor.
      expect(lru.totalBytes, 500);
      expect(lru.length, 1);
    });

    test('overwriting an existing key updates byte total', () {
      final lru = LruCache<String, Uint8List?>(1000, sizeOf);
      lru.put('k', blob(100));
      expect(lru.totalBytes, 100);
      lru.put('k', blob(300));
      expect(lru.totalBytes, 300);
      expect(lru.length, 1);
    });
  });
}
