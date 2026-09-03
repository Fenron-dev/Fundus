/// Shared, transport-independent definitions for Fundus' media hierarchy.
///
/// A work can be local, remote or offline without changing its content model.
/// The registry describes how a detail page labels and orders its content;
/// it deliberately does not prescribe the physical folder layout.
library;

enum FundusProgressKind { none, time, pages, chapters, items }

enum FundusDetailTab {
  info,
  content,
  files,
  notes,
  annotations,
  similar,
  devices,
}

enum FundusPlayerCapability {
  playback,
  reading,
  zoom,
  audioTracks,
  subtitles,
  screenshots,
}

enum FundusContentSensitivity { normal, adult }

final class FundusContentLevel {
  const FundusContentLevel({
    required this.id,
    required this.label,
    required this.pluralLabel,
    this.optional = false,
    this.virtual = false,
  });

  final String id;
  final String label;
  final String pluralLabel;

  /// Optional levels (for example a manga arc) are shown when the source has
  /// that grouping, but are not required to open a work.
  final bool optional;

  /// Virtual levels are derived from metadata/properties instead of folders.
  final bool virtual;
}

final class FundusMediaTypeDefinition {
  const FundusMediaTypeDefinition({
    required this.id,
    required this.label,
    required this.pluralLabel,
    required this.iconKey,
    required this.primaryActionLabel,
    required this.contentTabLabel,
    required this.contentLevels,
    required this.playerCapabilities,
    required this.progressKind,
    this.sensitivity = FundusContentSensitivity.normal,
    this.supportsCollections = false,
  });

  final String id;
  final String label;
  final String pluralLabel;
  final String iconKey;
  final String primaryActionLabel;
  final String contentTabLabel;
  final List<FundusContentLevel> contentLevels;
  final Set<FundusPlayerCapability> playerCapabilities;
  final FundusProgressKind progressKind;
  final FundusContentSensitivity sensitivity;
  final bool supportsCollections;

  /// All work pages share these sections.  `content` is labelled according to
  /// [contentTabLabel] by the consuming UI.
  List<FundusDetailTab> get detailTabs => const [
    FundusDetailTab.info,
    FundusDetailTab.content,
    FundusDetailTab.files,
    FundusDetailTab.notes,
    FundusDetailTab.annotations,
    FundusDetailTab.similar,
    FundusDetailTab.devices,
  ];

  bool hasLevel(String id) => contentLevels.any((level) => level.id == id);

  FundusContentLevel? level(String id) {
    for (final candidate in contentLevels) {
      if (candidate.id == id) return candidate;
    }
    return null;
  }
}

/// Canonical media vocabulary used by the shared LibraryShell.
///
/// New formats should add a definition here instead of introducing another
/// bespoke detail-page hierarchy.  Properties such as genre, tags, TTRPG
/// rounds and manga arcs remain virtual facets unless the source explicitly
/// provides the corresponding level.
abstract final class FundusMediaTypes {
  static const film = FundusMediaTypeDefinition(
    id: 'film',
    label: 'Film',
    pluralLabel: 'Filme',
    iconKey: 'movie',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Dateien',
    contentLevels: [
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.playback,
      FundusPlayerCapability.audioTracks,
      FundusPlayerCapability.subtitles,
      FundusPlayerCapability.screenshots,
    },
    progressKind: FundusProgressKind.time,
    supportsCollections: true,
  );

  static const series = FundusMediaTypeDefinition(
    id: 'series',
    label: 'Serie',
    pluralLabel: 'Serien',
    iconKey: 'tv',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Folgen',
    contentLevels: [
      FundusContentLevel(
        id: 'season',
        label: 'Staffel',
        pluralLabel: 'Staffeln',
      ),
      FundusContentLevel(id: 'episode', label: 'Folge', pluralLabel: 'Folgen'),
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.playback,
      FundusPlayerCapability.audioTracks,
      FundusPlayerCapability.subtitles,
      FundusPlayerCapability.screenshots,
    },
    progressKind: FundusProgressKind.time,
  );

  static const animeSeries = FundusMediaTypeDefinition(
    id: 'anime_series',
    label: 'Anime-Serie',
    pluralLabel: 'Anime-Serien',
    iconKey: 'anime',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Folgen',
    contentLevels: seriesLevels,
    playerCapabilities: seriesPlayerCapabilities,
    progressKind: FundusProgressKind.time,
  );

  static const hhhSeries = FundusMediaTypeDefinition(
    id: 'hhh_series',
    label: 'HHH-Serie',
    pluralLabel: 'HHH-Serien',
    iconKey: 'explicit',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Folgen',
    contentLevels: seriesLevels,
    playerCapabilities: seriesPlayerCapabilities,
    progressKind: FundusProgressKind.time,
    sensitivity: FundusContentSensitivity.adult,
  );

  static const animeFilm = FundusMediaTypeDefinition(
    id: 'anime_film',
    label: 'Anime-Film',
    pluralLabel: 'Anime-Filme',
    iconKey: 'anime_movie',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Dateien',
    contentLevels: filmLevels,
    playerCapabilities: filmPlayerCapabilities,
    progressKind: FundusProgressKind.time,
    supportsCollections: true,
  );

  static const hhhFilm = FundusMediaTypeDefinition(
    id: 'hhh_film',
    label: 'HHH-Film',
    pluralLabel: 'HHH-Filme',
    iconKey: 'explicit_movie',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Dateien',
    contentLevels: filmLevels,
    playerCapabilities: filmPlayerCapabilities,
    progressKind: FundusProgressKind.time,
    sensitivity: FundusContentSensitivity.adult,
    supportsCollections: true,
  );

  static const manga = FundusMediaTypeDefinition(
    id: 'manga',
    label: 'Manga/Comic',
    pluralLabel: 'Manga & Comics',
    iconKey: 'book_open',
    primaryActionLabel: 'Lesen',
    contentTabLabel: 'Kapitel',
    contentLevels: [
      FundusContentLevel(
        id: 'arc',
        label: 'Arc',
        pluralLabel: 'Arcs',
        optional: true,
      ),
      FundusContentLevel(id: 'volume', label: 'Band', pluralLabel: 'Bände'),
      FundusContentLevel(
        id: 'chapter',
        label: 'Kapitel',
        pluralLabel: 'Kapitel',
      ),
      FundusContentLevel(id: 'page', label: 'Seite', pluralLabel: 'Seiten'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.reading,
      FundusPlayerCapability.zoom,
      FundusPlayerCapability.screenshots,
    },
    progressKind: FundusProgressKind.pages,
  );

  static const webnovel = FundusMediaTypeDefinition(
    id: 'webnovel',
    label: 'Webnovel/Lightnovel',
    pluralLabel: 'Webnovels',
    iconKey: 'article',
    primaryActionLabel: 'Lesen',
    contentTabLabel: 'Kapitel',
    contentLevels: [
      FundusContentLevel(
        id: 'chapter',
        label: 'Kapitel',
        pluralLabel: 'Kapitel',
      ),
      FundusContentLevel(id: 'text', label: 'Text', pluralLabel: 'Texte'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.reading,
      FundusPlayerCapability.zoom,
    },
    progressKind: FundusProgressKind.pages,
  );

  static const audiobook = FundusMediaTypeDefinition(
    id: 'audiobook',
    label: 'Hörbuch',
    pluralLabel: 'Hörbücher',
    iconKey: 'headphones',
    primaryActionLabel: 'Weiterhören',
    contentTabLabel: 'Kapitel',
    contentLevels: [
      FundusContentLevel(id: 'part', label: 'Teil', pluralLabel: 'Teile'),
      FundusContentLevel(
        id: 'chapter',
        label: 'Kapitel',
        pluralLabel: 'Kapitel',
      ),
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {FundusPlayerCapability.playback},
    progressKind: FundusProgressKind.time,
  );

  static const music = FundusMediaTypeDefinition(
    id: 'music',
    label: 'Musik',
    pluralLabel: 'Musik',
    iconKey: 'music_note',
    primaryActionLabel: 'Abspielen',
    contentTabLabel: 'Tracks',
    contentLevels: [
      FundusContentLevel(id: 'track', label: 'Track', pluralLabel: 'Tracks'),
    ],
    playerCapabilities: {FundusPlayerCapability.playback},
    progressKind: FundusProgressKind.time,
  );

  static const podcast = FundusMediaTypeDefinition(
    id: 'podcast',
    label: 'Podcast',
    pluralLabel: 'Podcasts',
    iconKey: 'podcast',
    primaryActionLabel: 'Weiterhören',
    contentTabLabel: 'Episoden',
    contentLevels: [
      FundusContentLevel(
        id: 'season',
        label: 'Staffel',
        pluralLabel: 'Staffeln',
      ),
      FundusContentLevel(
        id: 'episode',
        label: 'Episode',
        pluralLabel: 'Episoden',
      ),
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {FundusPlayerCapability.playback},
    progressKind: FundusProgressKind.time,
  );

  static const book = FundusMediaTypeDefinition(
    id: 'book',
    label: 'Buch/E-Book',
    pluralLabel: 'Bücher & E-Books',
    iconKey: 'menu_book',
    primaryActionLabel: 'Lesen',
    contentTabLabel: 'Kapitel',
    contentLevels: [
      FundusContentLevel(
        id: 'chapter',
        label: 'Kapitel',
        pluralLabel: 'Kapitel',
      ),
      FundusContentLevel(id: 'text', label: 'Text', pluralLabel: 'Texte'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.reading,
      FundusPlayerCapability.zoom,
    },
    progressKind: FundusProgressKind.pages,
  );

  static const pdf = FundusMediaTypeDefinition(
    id: 'pdf',
    label: 'Dokument/PDF',
    pluralLabel: 'Dokumente',
    iconKey: 'picture_as_pdf',
    primaryActionLabel: 'Öffnen',
    contentTabLabel: 'Inhalt',
    contentLevels: [
      FundusContentLevel(
        id: 'section',
        label: 'Abschnitt',
        pluralLabel: 'Abschnitte',
      ),
      FundusContentLevel(id: 'page', label: 'Seite', pluralLabel: 'Seiten'),
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.reading,
      FundusPlayerCapability.zoom,
      FundusPlayerCapability.screenshots,
    },
    progressKind: FundusProgressKind.pages,
  );

  static const ttrpg = FundusMediaTypeDefinition(
    id: 'ttrpg',
    label: 'TTRPG-Produkt',
    pluralLabel: 'TTRPG',
    iconKey: 'casino',
    primaryActionLabel: 'Öffnen',
    contentTabLabel: 'Dateien',
    contentLevels: [
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.reading,
      FundusPlayerCapability.zoom,
      FundusPlayerCapability.screenshots,
    },
    progressKind: FundusProgressKind.pages,
  );

  static const photo = FundusMediaTypeDefinition(
    id: 'photo',
    label: 'Foto/Bild',
    pluralLabel: 'Fotos & Bilder',
    iconKey: 'image',
    primaryActionLabel: 'Öffnen',
    contentTabLabel: 'Bilder',
    contentLevels: [
      FundusContentLevel(
        id: 'stack',
        label: 'Stapel',
        pluralLabel: 'Stapel',
        optional: true,
      ),
      FundusContentLevel(id: 'asset', label: 'Bild', pluralLabel: 'Bilder'),
    ],
    playerCapabilities: {
      FundusPlayerCapability.reading,
      FundusPlayerCapability.zoom,
      FundusPlayerCapability.screenshots,
    },
    progressKind: FundusProgressKind.items,
  );

  static const archive = FundusMediaTypeDefinition(
    id: 'archive',
    label: 'Archiv',
    pluralLabel: 'Archive',
    iconKey: 'archive',
    primaryActionLabel: 'Öffnen',
    contentTabLabel: 'Inhalt',
    contentLevels: [
      FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
    ],
    playerCapabilities: {},
    progressKind: FundusProgressKind.none,
  );

  static const filmLevels = [
    FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
  ];
  static const filmPlayerCapabilities = {
    FundusPlayerCapability.playback,
    FundusPlayerCapability.audioTracks,
    FundusPlayerCapability.subtitles,
    FundusPlayerCapability.screenshots,
  };
  static const seriesLevels = [
    FundusContentLevel(id: 'season', label: 'Staffel', pluralLabel: 'Staffeln'),
    FundusContentLevel(id: 'episode', label: 'Folge', pluralLabel: 'Folgen'),
    FundusContentLevel(id: 'file', label: 'Datei', pluralLabel: 'Dateien'),
  ];
  static const seriesPlayerCapabilities = filmPlayerCapabilities;
}

abstract final class FundusMediaTypeRegistry {
  static const all = <FundusMediaTypeDefinition>[
    FundusMediaTypes.film,
    FundusMediaTypes.series,
    FundusMediaTypes.animeSeries,
    FundusMediaTypes.hhhSeries,
    FundusMediaTypes.animeFilm,
    FundusMediaTypes.hhhFilm,
    FundusMediaTypes.manga,
    FundusMediaTypes.webnovel,
    FundusMediaTypes.audiobook,
    FundusMediaTypes.music,
    FundusMediaTypes.podcast,
    FundusMediaTypes.book,
    FundusMediaTypes.pdf,
    FundusMediaTypes.ttrpg,
    FundusMediaTypes.photo,
    FundusMediaTypes.archive,
  ];

  static FundusMediaTypeDefinition? byId(String id) {
    for (final definition in all) {
      if (definition.id == id) return definition;
    }
    return null;
  }

  /// Resolves the persisted library fields to one shared definition.  The
  /// resolver keeps provider-specific values (`movie`, `tv`, `ttrpg_product`,
  /// …) at the boundary so the UI can work with one vocabulary.
  static FundusMediaTypeDefinition? forWork({
    required String kind,
    String? contentStyle,
    String? contentSensitivity,
  }) {
    final normalizedKind = kind.trim().toLowerCase();
    final style = contentStyle?.trim().toLowerCase();
    final adult =
        contentSensitivity == 'adult_explicit' ||
        contentSensitivity == 'adult' ||
        normalizedKind.startsWith('hhh_');
    final anime =
        style == 'anime' || style == 'anime_series' || style == 'anime_film';
    switch (normalizedKind) {
      case 'movie':
      case 'anime_movie':
      case 'hhh_movie':
        return adult
            ? FundusMediaTypes.hhhFilm
            : (normalizedKind == 'anime_movie' || anime
                  ? FundusMediaTypes.animeFilm
                  : FundusMediaTypes.film);
      case 'tv':
      case 'video':
      case 'anime_tv':
      case 'hhh_tv':
        return adult
            ? FundusMediaTypes.hhhSeries
            : (normalizedKind == 'anime_tv' || anime
                  ? FundusMediaTypes.animeSeries
                  : FundusMediaTypes.series);
      case 'audiobook':
        return FundusMediaTypes.audiobook;
      case 'manga':
      case 'comic':
        return FundusMediaTypes.manga;
      case 'webnovel':
        return FundusMediaTypes.webnovel;
      case 'music':
      case 'album':
        return FundusMediaTypes.music;
      case 'podcast':
        return FundusMediaTypes.podcast;
      case 'ebook':
      case 'book':
        return FundusMediaTypes.book;
      case 'pdf':
      case 'document':
        return FundusMediaTypes.pdf;
      case 'ttrpg':
      case 'ttrpg_product':
        return FundusMediaTypes.ttrpg;
      case 'image':
      case 'photo':
        return FundusMediaTypes.photo;
      case 'archive':
        return FundusMediaTypes.archive;
      default:
        return null;
    }
  }
}
