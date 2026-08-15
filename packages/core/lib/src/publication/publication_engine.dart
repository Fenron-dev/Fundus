import 'dart:async';

import '../model/media_position.dart';

enum PublicationRendererKind { reflow, fixedDocument, comic, plainText }

enum MediaEngineCapability {
  pageSeeking,
  chapterNavigation,
  tableOfContents,
  search,
  zoom,
  layout,
  readingDirection,
  continuousScroll,
  textSelection,
  annotations,
  forms,
  externalOpen,
}

enum MediaEngineCommand {
  previousPage,
  nextPage,
  previousChapter,
  nextChapter,
  toggleControls,
}

enum PublicationReaderLayout {
  singlePage,
  doublePage,
  continuousVertical,
  continuousHorizontal,
  webtoon,
}

enum PublicationReadingDirection { leftToRight, rightToLeft }

enum PublicationPageScale { fitScreen, fitWidth, fitHeight, original }

final class PublicationReaderProfile {
  const PublicationReaderProfile({
    this.layout = PublicationReaderLayout.singlePage,
    this.readingDirection = PublicationReadingDirection.leftToRight,
    this.pageScale = PublicationPageScale.fitScreen,
    this.firstPageIsCover = true,
    this.pageGap = 8,
    this.preloadCount = 2,
  }) : assert(pageGap >= 0 && pageGap <= 64),
       assert(preloadCount >= 0 && preloadCount <= 8);

  static const schemaVersion = 1;

  final PublicationReaderLayout layout;
  final PublicationReadingDirection readingDirection;
  final PublicationPageScale pageScale;
  final bool firstPageIsCover;
  final double pageGap;
  final int preloadCount;

  PublicationReaderProfile copyWith({
    PublicationReaderLayout? layout,
    PublicationReadingDirection? readingDirection,
    PublicationPageScale? pageScale,
    bool? firstPageIsCover,
    double? pageGap,
    int? preloadCount,
  }) => PublicationReaderProfile(
    layout: layout ?? this.layout,
    readingDirection: readingDirection ?? this.readingDirection,
    pageScale: pageScale ?? this.pageScale,
    firstPageIsCover: firstPageIsCover ?? this.firstPageIsCover,
    pageGap: pageGap ?? this.pageGap,
    preloadCount: preloadCount ?? this.preloadCount,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'layout': layout.name,
    'reading_direction': readingDirection.name,
    'page_scale': pageScale.name,
    'first_page_is_cover': firstPageIsCover,
    'page_gap': pageGap,
    'preload_count': preloadCount,
  };

  factory PublicationReaderProfile.fromJson(Map<String, Object?> json) {
    if (json['schema_version'] != schemaVersion) {
      throw const FormatException('Nicht unterstütztes Reader-Profil.');
    }
    final pageGap = (json['page_gap'] as num?)?.toDouble();
    final preloadCount = json['preload_count'];
    if (pageGap == null ||
        !pageGap.isFinite ||
        pageGap < 0 ||
        pageGap > 64 ||
        preloadCount is! int ||
        preloadCount < 0 ||
        preloadCount > 8 ||
        json['first_page_is_cover'] is! bool) {
      throw const FormatException('Ungültige Reader-Profilwerte.');
    }
    return PublicationReaderProfile(
      layout: PublicationReaderLayout.values.byName(json['layout'] as String),
      readingDirection: PublicationReadingDirection.values.byName(
        json['reading_direction'] as String,
      ),
      pageScale: PublicationPageScale.values.byName(
        json['page_scale'] as String,
      ),
      firstPageIsCover: json['first_page_is_cover'] as bool,
      pageGap: pageGap,
      preloadCount: preloadCount,
    );
  }
}

final class PublicationFormatDescriptor {
  const PublicationFormatDescriptor({
    required this.format,
    required this.renderer,
    required this.positionKind,
    required this.capabilities,
  });

  final String format;
  final PublicationRendererKind renderer;
  final MediaPositionKind positionKind;
  final Set<MediaEngineCapability> capabilities;

  bool supports(MediaEngineCapability capability) =>
      capabilities.contains(capability);
}

abstract interface class PublicationEngine {
  PublicationFormatDescriptor? probe(String sourcePath);

  Future<void> prepare(String sourcePath);

  Future<void> open(MediaPosition? initialPosition);

  Stream<MediaPosition> get positions;

  Future<void> seek(MediaPosition position);

  Future<void> command(MediaEngineCommand command);

  Future<MediaPosition?> snapshot();

  Future<void> close();
}

final class PublicationFormatRegistry {
  const PublicationFormatRegistry();

  PublicationFormatDescriptor? probe(String sourcePath) {
    final separator = sourcePath.lastIndexOf('.');
    if (separator < 0) return null;
    return descriptorForExtension(sourcePath.substring(separator));
  }

  PublicationFormatDescriptor? descriptorForExtension(String extension) =>
      switch (_normalize(extension)) {
        '.epub' => epub,
        '.pdf' => pdf,
        '.cbz' => cbz,
        '.txt' || '.md' || '.markdown' => plainText,
        _ => null,
      };

  static String _normalize(String extension) {
    final normalized = extension.trim().toLowerCase();
    return normalized.startsWith('.') ? normalized : '.$normalized';
  }

  static const epub = PublicationFormatDescriptor(
    format: 'EPUB',
    renderer: PublicationRendererKind.reflow,
    positionKind: MediaPositionKind.epubCfi,
    capabilities: {
      MediaEngineCapability.chapterNavigation,
      MediaEngineCapability.tableOfContents,
      MediaEngineCapability.search,
      MediaEngineCapability.layout,
      MediaEngineCapability.readingDirection,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );

  static const pdf = PublicationFormatDescriptor(
    format: 'PDF',
    renderer: PublicationRendererKind.fixedDocument,
    positionKind: MediaPositionKind.page,
    capabilities: {
      MediaEngineCapability.pageSeeking,
      MediaEngineCapability.search,
      MediaEngineCapability.zoom,
      MediaEngineCapability.layout,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.forms,
      MediaEngineCapability.externalOpen,
    },
  );

  static const cbz = PublicationFormatDescriptor(
    format: 'CBZ',
    renderer: PublicationRendererKind.comic,
    positionKind: MediaPositionKind.imageIndex,
    capabilities: {
      MediaEngineCapability.pageSeeking,
      MediaEngineCapability.chapterNavigation,
      MediaEngineCapability.zoom,
      MediaEngineCapability.layout,
      MediaEngineCapability.readingDirection,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );

  static const plainText = PublicationFormatDescriptor(
    format: 'Text',
    renderer: PublicationRendererKind.plainText,
    positionKind: MediaPositionKind.epubCfi,
    capabilities: {
      MediaEngineCapability.search,
      MediaEngineCapability.layout,
      MediaEngineCapability.continuousScroll,
      MediaEngineCapability.textSelection,
      MediaEngineCapability.annotations,
      MediaEngineCapability.externalOpen,
    },
  );
}
