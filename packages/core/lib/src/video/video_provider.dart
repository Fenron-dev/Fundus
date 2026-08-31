/// Provider-neutral metadata used to enrich video works.
///
/// The core package deliberately contains no HTTP client or credentials. App
/// and server adapters can map AniList, TMDB or another source to these
/// portable values and persist only the provider id and selected metadata.
final class VideoProviderCandidate {
  const VideoProviderCandidate({
    required this.provider,
    required this.providerId,
    required this.title,
    this.alternateTitles = const [],
    this.videoKind,
    this.contentStyle,
    this.contentSensitivity,
    this.releaseYear,
    this.season,
    this.episodeCount,
    this.isAdult,
    this.description,
    this.genres = const [],
    this.posterUrl,
    this.backdropUrl,
    this.externalIds = const {},
  });

  final String provider;
  final String providerId;
  final String title;
  final List<String> alternateTitles;
  final String? videoKind;
  final String? contentStyle;
  final String? contentSensitivity;
  final int? releaseYear;
  final int? season;
  final int? episodeCount;
  final bool? isAdult;
  final String? description;
  final List<String> genres;
  final String? posterUrl;
  final String? backdropUrl;
  final Map<String, String> externalIds;

  Map<String, Object?> toJson() => {
    'provider': provider,
    'provider_id': providerId,
    'title': title,
    if (alternateTitles.isNotEmpty) 'alternate_titles': alternateTitles,
    if (videoKind != null) 'video_kind': videoKind,
    if (contentStyle != null) 'content_style': contentStyle,
    if (contentSensitivity != null) 'content_sensitivity': contentSensitivity,
    if (releaseYear != null) 'release_year': releaseYear,
    if (season != null) 'season': season,
    if (episodeCount != null) 'episode_count': episodeCount,
    if (isAdult != null) 'is_adult': isAdult,
    if (description != null) 'description': description,
    if (genres.isNotEmpty) 'genres': genres,
    if (posterUrl != null) 'poster_url': posterUrl,
    if (backdropUrl != null) 'backdrop_url': backdropUrl,
    if (externalIds.isNotEmpty) 'external_ids': externalIds,
  };

  static VideoProviderCandidate? fromJson(Object? value) {
    if (value is! Map ||
        value['provider'] is! String ||
        value['provider_id'] is! String ||
        value['title'] is! String) {
      return null;
    }
    final alternateTitles = value['alternate_titles'];
    final externalIds = value['external_ids'];
    final genres = value['genres'];
    return VideoProviderCandidate(
      provider: value['provider'] as String,
      providerId: value['provider_id'] as String,
      title: value['title'] as String,
      alternateTitles: alternateTitles is List
          ? alternateTitles.whereType<String>().toList(growable: false)
          : const [],
      videoKind: value['video_kind'] as String?,
      contentStyle: value['content_style'] as String?,
      contentSensitivity: value['content_sensitivity'] as String?,
      releaseYear: (value['release_year'] as num?)?.round(),
      season: (value['season'] as num?)?.round(),
      episodeCount: (value['episode_count'] as num?)?.round(),
      isAdult: value['is_adult'] as bool?,
      description: value['description'] as String?,
      genres: genres is List
          ? genres.whereType<String>().toList(growable: false)
          : const [],
      posterUrl: value['poster_url'] as String?,
      backdropUrl: value['backdrop_url'] as String?,
      externalIds: externalIds is Map
          ? {
              for (final entry in externalIds.entries)
                if (entry.key is String && entry.value is String)
                  entry.key as String: entry.value as String,
            }
          : const {},
    );
  }
}

final class VideoProviderMatch {
  const VideoProviderMatch({
    required this.candidate,
    required this.score,
    this.reasons = const [],
  });

  final VideoProviderCandidate candidate;
  final double score;
  final List<String> reasons;

  bool get needsConfirmation => score < .92;
}

/// Ranks provider candidates locally so a network adapter can stay simple and
/// a user can see why an automatic match was suggested.
List<VideoProviderMatch> rankVideoProviderMatches(
  String query,
  Iterable<VideoProviderCandidate> candidates,
) {
  final normalizedQuery = _normalizeVideoTitle(query);
  if (normalizedQuery.isEmpty) return const [];
  final queryTokens = normalizedQuery.split(' ').toSet();
  final matches = <VideoProviderMatch>[];
  for (final candidate in candidates) {
    final titles = [candidate.title, ...candidate.alternateTitles]
        .map(_normalizeVideoTitle)
        .where((title) => title.isNotEmpty)
        .toList(growable: false);
    var bestScore = 0.0;
    var bestTitle = candidate.title;
    for (final title in titles) {
      final titleTokens = title.split(' ').toSet();
      final overlap = queryTokens.intersection(titleTokens).length;
      final tokenScore = overlap / queryTokens.length;
      final score = title == normalizedQuery
          ? 1.0
          : title.startsWith(normalizedQuery) ||
                normalizedQuery.startsWith(title)
          ? .9
          : tokenScore * .8;
      if (score > bestScore) {
        bestScore = score;
        bestTitle = title;
      }
    }
    if (bestScore <= 0) continue;
    matches.add(
      VideoProviderMatch(
        candidate: candidate,
        score: bestScore.clamp(0, 1),
        reasons: [
          if (bestTitle == normalizedQuery) 'Exakter Titel',
          if (bestTitle != normalizedQuery && bestScore >= .9) 'Titelpräfix',
          if (bestScore < .9) 'Gemeinsame Titelwörter',
        ],
      ),
    );
  }
  matches.sort((left, right) {
    final score = right.score.compareTo(left.score);
    if (score != 0) return score;
    return left.candidate.title.toLowerCase().compareTo(
      right.candidate.title.toLowerCase(),
    );
  });
  return matches;
}

String _normalizeVideoTitle(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[._:/\\-]+'), ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N} ]', unicode: true), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
