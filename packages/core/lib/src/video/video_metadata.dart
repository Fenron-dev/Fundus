import 'package:path/path.dart' as p;

/// The part of a video filename that identifies an episode in a series.
///
/// Movie files intentionally return `null`; they remain addressable by their
/// work identity and do not acquire a synthetic season or episode number.
final class VideoEpisodeIdentity {
  const VideoEpisodeIdentity({
    required this.season,
    required this.episode,
    required this.title,
    this.episodeEnd,
    this.absoluteEpisode,
    this.special = false,
  });

  final int season;
  final int episode;
  final String title;
  final int? episodeEnd;
  final int? absoluteEpisode;
  final bool special;

  String get label {
    if (absoluteEpisode != null) {
      return 'E${absoluteEpisode!.toString().padLeft(3, '0')}';
    }
    final first =
        'S${season.toString().padLeft(2, '0')}E'
        '${episode.toString().padLeft(2, '0')}';
    if (episodeEnd == null || episodeEnd == episode) return first;
    return '$first-E${episodeEnd!.toString().padLeft(2, '0')}';
  }

  Map<String, Object?> toJson() => {
    'season': season,
    'episode': episode,
    if (episodeEnd != null) 'episode_end': episodeEnd,
    if (absoluteEpisode != null) 'absolute_episode': absoluteEpisode,
    if (special) 'special': true,
    'label': label,
    'title': title,
  };

  static VideoEpisodeIdentity? fromJson(Object? value) {
    if (value is! Map) return null;
    final season = value['season'];
    final episode = value['episode'];
    if (season is! int || episode is! int || season < 0 || episode < 0) {
      return null;
    }
    final title = value['title'];
    return VideoEpisodeIdentity(
      season: season,
      episode: episode,
      title: title is String ? title : '',
      episodeEnd: (value['episode_end'] as num?)?.round(),
      absoluteEpisode: (value['absolute_episode'] as num?)?.round(),
      special: value['special'] == true,
    );
  }
}

Map<String, Object?> videoEpisodeToJson(VideoEpisodeIdentity episode) =>
    episode.toJson();

VideoEpisodeIdentity? videoEpisodeFromJson(Object? value) =>
    VideoEpisodeIdentity.fromJson(value);

/// Parses common season/episode forms without making the folder layout part of
/// the media identity. Provider metadata can replace the title later.
VideoEpisodeIdentity? parseVideoEpisode(String filename) {
  final basename = p.basenameWithoutExtension(filename).trim();
  if (basename.isEmpty) return null;
  final seasonMatch = RegExp(
    r'(?:^|[^a-z])s(\d{1,3})\s*[._ -]?\s*e(\d{1,4})(?=[^0-9]|$)',
    caseSensitive: false,
  ).firstMatch(basename);
  final compactMatch = seasonMatch == null
      ? RegExp(
          r'(?:^|[^0-9])(\d{1,3})x(\d{1,4})(?:[^0-9]|$)',
          caseSensitive: false,
        ).firstMatch(basename)
      : null;
  final seasonEpisodeMatch = seasonMatch ?? compactMatch;
  if (seasonEpisodeMatch != null) {
    final season = int.tryParse(seasonEpisodeMatch.group(1)!);
    final episode = int.tryParse(seasonEpisodeMatch.group(2)!);
    if (season == null || episode == null || season < 0 || episode < 0) {
      return null;
    }
    final remainder = basename.substring(seasonEpisodeMatch.end);
    final endMatch = RegExp(
      r'^\s*(?:[-&+]\s*)e?\s*(\d{1,4})',
      caseSensitive: false,
    ).firstMatch(remainder);
    final episodeEnd = endMatch == null
        ? null
        : int.tryParse(endMatch.group(1)!);
    final consumedEnd = endMatch == null
        ? seasonEpisodeMatch.end
        : seasonEpisodeMatch.end + endMatch.end;
    final title = basename
        .replaceRange(seasonEpisodeMatch.start, consumedEnd, ' ')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s*-\s*-\s*'), ' - ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return VideoEpisodeIdentity(
      season: season,
      episode: episode,
      episodeEnd: episodeEnd,
      special: season == 0,
      title: title,
    );
  }

  // Absolute anime numbering is intentionally conservative. The explicit
  // marker/delimiter prevents years and resolution tokens being misclassified.
  final absoluteMatch = RegExp(
    r'(?:^|\s)(?:-\s*)?(?:episode|ep)\s*#?\s*(\d{1,4})(?:\s*[-&+]\s*(\d{1,4}))?(?=\s*(?:[-_.]|$))',
    caseSensitive: false,
  ).firstMatch(basename);
  final delimitedAbsoluteMatch = absoluteMatch == null
      ? RegExp(
          r'(?:^|\s)-\s*(\d{1,4})(?:\s*[-&+]\s*(\d{1,4}))?\s*(?=-\s|[-_.]|$)',
          caseSensitive: false,
        ).firstMatch(basename)
      : null;
  final absolute = absoluteMatch ?? delimitedAbsoluteMatch;
  if (absolute == null) return null;
  final absoluteEpisode = int.tryParse(absolute.group(1)!);
  if (absoluteEpisode == null || absoluteEpisode < 0) return null;
  final absoluteEnd = absolute.group(2) == null
      ? null
      : int.tryParse(absolute.group(2)!);
  final title = basename
      .replaceRange(absolute.start, absolute.end, ' ')
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'\s*-\s*-\s*'), ' - ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return VideoEpisodeIdentity(
    season: 1,
    episode: absoluteEpisode,
    episodeEnd: absoluteEnd,
    absoluteEpisode: absoluteEpisode,
    title: title,
  );
}
