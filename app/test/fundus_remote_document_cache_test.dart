import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_document_cache.dart';

void main() {
  test('downloads remote content atomically and reuses the cache', () async {
    final root = await Directory.systemTemp.createTemp('fundus-doc-cache-');
    addTearDown(() => root.delete(recursive: true));
    final cache = FundusRemoteDocumentCache(root: root);
    var requests = 0;

    Future<FundusRemoteDocumentSource> open() async {
      requests++;
      return _stream([1, 2, 3]);
    }

    final first = await cache.obtain(
      cacheKey: 'server/library/file',
      filename: 'Handout.PDF',
      open: open,
    );
    final second = await cache.obtain(
      cacheKey: 'server/library/file',
      filename: 'Handout.PDF',
      open: open,
    );

    expect(first.path, endsWith('.pdf'));
    expect(await first.readAsBytes(), [1, 2, 3]);
    expect(second.path, first.path);
    expect(requests, 1);
    expect(root.listSync().whereType<File>(), hasLength(1));
  });

  test('rejects oversized streams and removes partial files', () async {
    final root = await Directory.systemTemp.createTemp('fundus-doc-limit-');
    addTearDown(() => root.delete(recursive: true));
    final cache = FundusRemoteDocumentCache(root: root, maximumBytes: 2);

    await expectLater(
      cache.obtain(
        cacheKey: 'large',
        filename: 'map.png',
        open: () async => _stream([1, 2, 3]),
      ),
      throwsA(isA<FundusRemoteDocumentException>()),
    );
    expect(root.listSync().whereType<File>(), isEmpty);
  });
}

FundusRemoteDocumentSource _stream(List<int> bytes) =>
    FundusRemoteDocumentSource(
      bytes: Stream.value(bytes),
      contentLength: bytes.length,
      close: () {},
    );
