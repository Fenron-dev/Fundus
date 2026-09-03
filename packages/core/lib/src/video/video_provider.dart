/// A person attached to a provider result (actor, voice actor, director, …).
///
/// The object intentionally contains only display-safe values so it can be
/// stored in a portable sidecar and transported to remote/offline clients.
final class VideoProviderCredit {
  const VideoProviderCredit({
    required this.name,
    this.role,
    this.imageUrl,
    this.providerId,
  });

  final String name;
  final String? role;
  final String? imageUrl;
  final String? providerId;

  Map<String, Object?> toJson() => {
    'name': name,
    if (role != null && role!.trim().isNotEmpty) 'role': role,
    if (imageUrl != null && imageUrl!.trim().isNotEmpty) 'image_url': imageUrl,
    if (providerId != null && providerId!.trim().isNotEmpty)
      'provider_id': providerId,
  };

  static VideoProviderCredit? fromJson(Object? value) {
    if (value is! Map || value['name'] is! String) return null;
    final name = (value['name'] as String).trim();
    if (name.isEmpty) return null;
    return VideoProviderCredit(
      name: name,
      role: (value['role'] as String?)?.trim(),
      imageUrl: (value['image_url'] as String?)?.trim(),
      providerId: (value['provider_id'] as String?)?.trim(),
    );
  }
}

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
    this.runtimeMinutes,
    this.season,
    this.episodeCount,
    this.isAdult,
    this.description,
    this.genres = const [],
    this.posterUrl,
    this.backdropUrl,
    this.credits = const [],
    this.trailerUrl,
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

  /// Runtime in minutes when supplied by the metadata provider (for example
  /// AniList). Providers may omit this for search results that do not expose
  /// a duration.
  final int? runtimeMinutes;
  final int? season;
  final int? episodeCount;
  final bool? isAdult;
  final String? description;
  final List<String> genres;
  final String? posterUrl;
  final String? backdropUrl;
  final List<VideoProviderCredit> credits;
  final String? trailerUrl;
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
    if (runtimeMinutes != null) 'runtime_minutes': runtimeMinutes,
    if (season != null) 'season': season,
    if (episodeCount != null) 'episode_count': episodeCount,
    if (isAdult != null) 'is_adult': isAdult,
    if (description != null) 'description': description,
    if (genres.isNotEmpty) 'genres': genres,
    if (posterUrl != null) 'poster_url': posterUrl,
    if (backdropUrl != null) 'backdrop_url': backdropUrl,
    if (credits.isNotEmpty)
      'credits': [for (final credit in credits) credit.toJson()],
    if (trailerUrl != null && trailerUrl!.trim().isNotEmpty)
      'trailer_url': trailerUrl,
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
    final credits = value['credits'];
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
      runtimeMinutes: (value['runtime_minutes'] as num?)?.round(),
      season: (value['season'] as num?)?.round(),
      episodeCount: (value['episode_count'] as num?)?.round(),
      isAdult: value['is_adult'] as bool?,
      description: value['description'] as String?,
      genres: genres is List
          ? genres.whereType<String>().toList(growable: false)
          : const [],
      posterUrl: value['poster_url'] as String?,
      backdropUrl: value['backdrop_url'] as String?,
      credits: credits is List
          ? credits
                .map(VideoProviderCredit.fromJson)
                .whereType<VideoProviderCredit>()
                .toList(growable: false)
          : const [],
      trailerUrl: value['trailer_url'] as String?,
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
