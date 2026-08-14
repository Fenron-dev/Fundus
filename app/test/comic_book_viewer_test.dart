import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/comic_book_viewer.dart';
import 'package:fundus/library/zip_archive_browser.dart';

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
}
