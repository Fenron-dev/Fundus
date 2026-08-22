import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  const registry = PublicationFormatRegistry();

  test(
    'selects specialized renderers without depending on folder structure',
    () {
      expect(
        registry.probe('/library/anything/Book.EPUB')?.renderer,
        PublicationRendererKind.reflow,
      );
      expect(
        registry.probe('/library/Webnovels/Chapter 1.HTML')?.renderer,
        PublicationRendererKind.reflow,
      );
      expect(
        registry.probe('/library/Manga/Chapter 1.cbz')?.renderer,
        PublicationRendererKind.comic,
      );
      expect(
        registry.probe('/inbox/scan.pdf')?.renderer,
        PublicationRendererKind.fixedDocument,
      );
      expect(registry.probe('/library/audio.m4b'), isNull);
    },
  );

  test('capabilities are exposed by the selected engine descriptor', () {
    final comic = registry.descriptorForExtension('CBZ')!;
    final epub = registry.descriptorForExtension('.epub')!;
    final pdf = registry.descriptorForExtension('.PDF')!;

    expect(comic.positionKind, MediaPositionKind.imageIndex);
    expect(comic.supports(MediaEngineCapability.readingDirection), isTrue);
    expect(epub.positionKind, MediaPositionKind.epubCfi);
    expect(epub.supports(MediaEngineCapability.tableOfContents), isTrue);
    expect(pdf.positionKind, MediaPositionKind.page);
    expect(pdf.supports(MediaEngineCapability.forms), isTrue);
    expect(pdf.supports(MediaEngineCapability.readingDirection), isFalse);
  });

  test('reader profiles round-trip portable layout preferences', () {
    const profile = PublicationReaderProfile(
      layout: PublicationReaderLayout.doublePage,
      readingDirection: PublicationReadingDirection.rightToLeft,
      pageScale: PublicationPageScale.fitHeight,
      firstPageIsCover: false,
      pageGap: 12,
      readerWidth: .78,
      tapZoneWidth: .25,
      invertTapZones: true,
      preloadCount: 4,
      chapterTransition: PublicationChapterTransition.automatic,
      progressPlacement: PublicationProgressPlacement.left,
    );

    final restored = PublicationReaderProfile.fromJson(profile.toJson());
    expect(restored.layout, PublicationReaderLayout.doublePage);
    expect(restored.readingDirection, PublicationReadingDirection.rightToLeft);
    expect(restored.pageScale, PublicationPageScale.fitHeight);
    expect(restored.firstPageIsCover, isFalse);
    expect(restored.pageGap, 12);
    expect(restored.readerWidth, .78);
    expect(restored.tapZoneWidth, .25);
    expect(restored.invertTapZones, isTrue);
    expect(restored.preloadCount, 4);
    expect(restored.chapterTransition, PublicationChapterTransition.automatic);
    expect(restored.progressPlacement, PublicationProgressPlacement.left);
  });

  test('reader profile version one migrates to full reader width', () {
    final restored = PublicationReaderProfile.fromJson({
      'schema_version': 1,
      'layout': 'webtoon',
      'reading_direction': 'leftToRight',
      'page_scale': 'fitWidth',
      'first_page_is_cover': true,
      'page_gap': 0,
      'preload_count': 2,
    });

    expect(restored.layout, PublicationReaderLayout.webtoon);
    expect(restored.readerWidth, 1);
    expect(restored.tapZoneWidth, .3);
    expect(restored.invertTapZones, isFalse);
    expect(restored.chapterTransition, PublicationChapterTransition.confirm);
    expect(restored.progressPlacement, PublicationProgressPlacement.automatic);
  });

  test('reader profile version two migrates chapter transitions safely', () {
    final restored = PublicationReaderProfile.fromJson({
      'schema_version': 2,
      'layout': 'singlePage',
      'reading_direction': 'leftToRight',
      'page_scale': 'fitScreen',
      'first_page_is_cover': true,
      'page_gap': 8,
      'reader_width': 1,
      'tap_zone_width': .3,
      'invert_tap_zones': false,
      'preload_count': 2,
    });

    expect(restored.chapterTransition, PublicationChapterTransition.confirm);
    expect(restored.progressPlacement, PublicationProgressPlacement.automatic);
  });

  test('reader profile version three migrates progress placement safely', () {
    final restored = PublicationReaderProfile.fromJson({
      'schema_version': 3,
      'layout': 'singlePage',
      'reading_direction': 'leftToRight',
      'page_scale': 'fitScreen',
      'first_page_is_cover': true,
      'page_gap': 8,
      'reader_width': 1,
      'tap_zone_width': .3,
      'invert_tap_zones': false,
      'preload_count': 2,
      'chapter_transition': 'automatic',
    });

    expect(restored.chapterTransition, PublicationChapterTransition.automatic);
    expect(restored.progressPlacement, PublicationProgressPlacement.automatic);
  });
}
