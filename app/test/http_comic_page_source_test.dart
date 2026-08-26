import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_client.dart';
import 'package:fundus/server/http_comic_page_source.dart';

void main() {
  test('HTTP comic source fetches only materialized pages', () async {
    final requested = <int>[];
    final source = HttpComicPageSource(
      name: 'Kapitel 1.cbz',
      loadManifest: () async => const FundusRemoteComicManifest(
        fileId: 'file-1',
        pages: [
          FundusRemoteComicPage(
            index: 0,
            id: 'pages/001.png',
            name: '001.png',
            size: 3,
            mimeType: 'image/png',
            width: 800,
            height: 1200,
          ),
          FundusRemoteComicPage(
            index: 1,
            id: 'pages/002.png',
            name: '002.png',
            size: 4,
            mimeType: 'image/png',
            width: 800,
            height: 1200,
          ),
        ],
      ),
      loadPage: (index) async {
        requested.add(index);
        return index == 0
            ? Uint8List.fromList([1, 2, 3])
            : Uint8List.fromList([4, 5, 6, 7]);
      },
    );

    final pages = await source.pages();
    expect(pages, hasLength(2));
    expect(pages.first.id, 'pages/001.png');
    expect(pages.first.width, 800);
    expect(requested, isEmpty);

    final materialized = await source.materialize([pages[1]]);
    expect(requested, [1]);
    expect(await File(materialized[pages[1].id]!).readAsBytes(), [4, 5, 6, 7]);

    await source.materialize([pages[1]]);
    expect(requested, [1]);
    final cached = File(materialized[pages[1].id]!);
    await source.dispose();
    expect(await cached.exists(), isFalse);
  });
}
