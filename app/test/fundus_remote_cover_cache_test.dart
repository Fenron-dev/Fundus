import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_cover_cache.dart';

void main() {
  test('downloads covers atomically and reuses the persistent file', () async {
    final root = await Directory.systemTemp.createTemp('fundus-cover-cache-');
    addTearDown(() => root.delete(recursive: true));
    final cache = FundusRemoteCoverCache(root: root);
    var requests = 0;

    Future<Uint8List> open() async {
      requests++;
      return Uint8List.fromList([1, 2, 3]);
    }

    final first = await cache.obtain(
      cacheKey: 'server/library/work',
      open: open,
    );
    final second = await cache.obtain(
      cacheKey: 'server/library/work',
      open: open,
    );

    expect(first, isNotNull);
    expect(await first!.readAsBytes(), [1, 2, 3]);
    expect(second?.path, first.path);
    expect(requests, 1);
    expect(root.listSync().whereType<File>(), hasLength(1));
  });

  test(
    'rejects empty and oversized covers without leaving partial files',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-cover-limit-');
      addTearDown(() => root.delete(recursive: true));
      final cache = FundusRemoteCoverCache(root: root, maximumBytes: 2);

      expect(
        await cache.obtain(cacheKey: 'empty', open: () async => Uint8List(0)),
        isNull,
      );
      expect(
        await cache.obtain(
          cacheKey: 'large',
          open: () async => Uint8List.fromList([1, 2, 3]),
        ),
        isNull,
      );
      expect(root.listSync().whereType<File>(), isEmpty);
    },
  );
}
