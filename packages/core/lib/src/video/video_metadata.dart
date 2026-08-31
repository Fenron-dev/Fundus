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
  });

  final int season;
  final int episode;
  final String title;

  String get label =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() => {
    'season': season,
    'episode': episode,
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
  final match = RegExp(
    r'(?:^|[^a-z])s(\d{1,3})\s*[._ -]?\s*e(\d{1,4})(?:[^0-9]|$)',
    caseSensitive: false,
  ).firstMatch(basename);
  final compactMatch =
      match ??
      RegExp(
        r'(?:^|[^0-9])(\d{1,3})x(\d{1,4})(?:[^0-9]|$)',
        caseSensitive: false,
      ).firstMatch(basename);
  if (compactMatch == null) return null;
  final season = int.tryParse(compactMatch.group(1)!);
  final episode = int.tryParse(compactMatch.group(2)!);
  if (season == null || episode == null || season < 0 || episode < 0) {
    return null;
  }
  final title = basename
      .replaceRange(compactMatch.start, compactMatch.end, ' ')
      .replaceAll(RegExp(r'[._]+'), ' ')
      .replaceAll(RegExp(r'\s*-\s*-\s*'), ' - ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return VideoEpisodeIdentity(season: season, episode: episode, title: title);
}
