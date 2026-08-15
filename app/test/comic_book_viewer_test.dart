import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/comic_book_viewer.dart';
import 'package:fundus/library/zip_archive_browser.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('comic pages ignore non-images and use natural path ordering', () {
    const snapshot = ZipArchiveSnapshot(
      entries: [
        ZipArchiveEntry(
          path: 'pages/10.jpg',
          archiveName: 'pages/10.jpg',
          isDirectory: false,
          size: 10,
        ),
        ZipArchiveEntry(
          path: 'ComicInfo.xml',
          archiveName: 'ComicInfo.xml',
          isDirectory: false,
          size: 10,
        ),
        ZipArchiveEntry(
          path: 'pages/2.png',
          archiveName: 'pages/2.png',
          isDirectory: false,
          size: 10,
        ),
        ZipArchiveEntry(
          path: 'pages/1.webp',
          archiveName: 'pages/1.webp',
          isDirectory: false,
          size: 10,
        ),
      ],
    );

    expect(comicBookPages(snapshot).map((entry) => entry.path), [
      'pages/1.webp',
      'pages/2.png',
      'pages/10.jpg',
    ]);
  });

  test('double-page groups keep an optional cover on its own', () {
    expect(
      comicPageGroups(
        5,
        layout: PublicationReaderLayout.doublePage,
        firstPageIsCover: true,
      ),
      [
        [0],
        [1, 2],
        [3, 4],
      ],
    );
    expect(
      comicPageGroups(
        5,
        layout: PublicationReaderLayout.doublePage,
        firstPageIsCover: false,
      ),
      [
        [0, 1],
        [2, 3],
        [4],
      ],
    );
  });

  test('layout changes retain the group containing the current page', () {
    final groups = comicPageGroups(
      8,
      layout: PublicationReaderLayout.doublePage,
      firstPageIsCover: true,
    );

    expect(comicPageGroupIndex(groups, 0), 0);
    expect(comicPageGroupIndex(groups, 2), 1);
    expect(comicPageGroupIndex(groups, 7), 4);
    expect(comicPageLabel(groups, 2, 8), 'Seiten 2–3 von 8');
    expect(comicPageLabel(groups, 0, 8), 'Seite 1 von 8');
  });
}
