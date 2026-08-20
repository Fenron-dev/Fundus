import 'dart:ui' show Size;

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

  test('tap zones respect the configured edge width', () {
    expect(
      comicReaderTapZoneAt(10, 100, edgeFraction: .25),
      ComicReaderTapZone.left,
    );
    expect(
      comicReaderTapZoneAt(25, 100, edgeFraction: .25),
      ComicReaderTapZone.center,
    );
    expect(
      comicReaderTapZoneAt(50, 100, edgeFraction: .25),
      ComicReaderTapZone.center,
    );
    expect(
      comicReaderTapZoneAt(76, 100, edgeFraction: .25),
      ComicReaderTapZone.right,
    );
  });

  test('overall progress combines chapter and page positions', () {
    expect(comicOverallProgress(page: 4, pageCount: 10), .5);
    expect(
      comicOverallProgress(
        page: 4,
        pageCount: 10,
        chapterIndex: 1,
        chapterCount: 4,
      ),
      .375,
    );
    expect(comicOverallProgress(page: 99, pageCount: 10), 1);
  });

  test('chapter overview result carries the selected chapter', () {
    final result = ComicBookViewerResult.selectChapter(7);

    expect(result.action, ComicBookViewerAction.selectChapter);
    expect(result.chapterIndex, 7);
    expect(
      ComicBookViewerResult.nextChapter.action,
      ComicBookViewerAction.nextChapter,
    );
    final bookmarkPosition = MediaPosition(
      kind: MediaPositionKind.imageIndex,
      numericValue: 4,
      fileId: 'chapter-2',
    );
    final bookmarkResult = ComicBookViewerResult.selectBookmark(
      bookmarkPosition,
    );
    expect(bookmarkResult.action, ComicBookViewerAction.selectBookmark);
    expect(bookmarkResult.position, same(bookmarkPosition));
  });

  test('automatic progress placement follows the available width', () {
    expect(
      comicProgressPlacementFor(PublicationProgressPlacement.automatic, 600),
      PublicationProgressPlacement.bottom,
    );
    expect(
      comicProgressPlacementFor(PublicationProgressPlacement.automatic, 1200),
      PublicationProgressPlacement.right,
    );
    expect(
      comicProgressPlacementFor(PublicationProgressPlacement.left, 1200),
      PublicationProgressPlacement.left,
    );
  });

  test(
    'continuous readers retain earlier page futures for stable scrolling',
    () {
      expect(
        comicShouldEvictCachedPage(
          continuous: true,
          cachedPage: 1,
          currentPage: 20,
          preloadCount: 2,
        ),
        isFalse,
      );
      expect(
        comicShouldEvictCachedPage(
          continuous: false,
          cachedPage: 1,
          currentPage: 20,
          preloadCount: 2,
        ),
        isTrue,
      );
    },
  );

  test('webtoon restore uses measured page heights and inner offset', () {
    final offset = comicContinuousRestoreOffset(
      page: 2,
      pageOffset: .5,
      pageSizes: const [Size(100, 1000), Size(100, 800), Size(100, 1200)],
      viewport: const Size(500, 800),
      profile: const PublicationReaderProfile(
        layout: PublicationReaderLayout.webtoon,
        pageScale: PublicationPageScale.fitWidth,
      ),
    );

    expect(offset, 11600);
  });

  test('chapter sequence reports missing and duplicate chapter numbers', () {
    final report = comicChapterSequenceReport([
      'Serie – Kapitel 0280',
      'Serie – Chapter 281',
      'Serie – Kapitel 0283',
      'Alternative – Kapitel 0283',
      'Bonus ohne Nummer',
    ]);

    expect(report.numbersByIndex, [280, 281, 283, 283, null]);
    expect(report.missingNumbers, [282]);
    expect(report.duplicateNumbers, {283});
    expect(report.hasIssues, isTrue);
  });

  test('chapter sequence supports decimal chapters without false gaps', () {
    final report = comicChapterSequenceReport([
      'Kapitel 10',
      'Kapitel 10.5',
      'Kapitel 11',
    ]);

    expect(report.missingNumbers, isEmpty);
    expect(report.duplicateNumbers, isEmpty);
  });
}
