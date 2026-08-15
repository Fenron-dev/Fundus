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
      preloadCount: 4,
    );

    final restored = PublicationReaderProfile.fromJson(profile.toJson());
    expect(restored.layout, PublicationReaderLayout.doublePage);
    expect(restored.readingDirection, PublicationReadingDirection.rightToLeft);
    expect(restored.pageScale, PublicationPageScale.fitHeight);
    expect(restored.firstPageIsCover, isFalse);
    expect(restored.pageGap, 12);
    expect(restored.preloadCount, 4);
  });
}
