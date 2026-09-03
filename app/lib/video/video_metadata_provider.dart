import 'dart:async';
import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

/// A provider error intentionally contains no request URL or credentials.
final class VideoProviderException implements Exception {
  const VideoProviderException(this.provider, this.message);

  final String provider;
  final String message;

  @override
  String toString() => '$provider: $message';
}

abstract interface class VideoMetadataProvider {
  String get provider;

  Future<List<VideoProviderCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  });
}

/// Combines configured providers and applies the same local ranking rules to
/// all results. A failing optional provider never hides results from others.
final class VideoMetadataService {
  const VideoMetadataService(this.providers);

  final List<VideoMetadataProvider> providers;

  Future<List<VideoProviderMatch>> search(
    String query, {
    int limitPerProvider = 10,
    String? language,
  }) async {
    final responses = await Future.wait([
      for (final provider in providers)
        _safeSearch(provider, query, limitPerProvider, language),
    ]);
    return rankVideoProviderMatches(
      query,
      responses.expand((candidates) => candidates),
    );
  }

  Future<List<VideoProviderCandidate>> _safeSearch(
    VideoMetadataProvider provider,
    String query,
    int limit,
    String? language,
  ) async {
    try {
      return await provider.search(query, limit: limit, language: language);
    } on Object {
      return const [];
    }
  }
}

/// Public AniList GraphQL search. No account or API key is required.
final class AniListVideoProvider implements VideoMetadataProvider {
  AniListVideoProvider({http.Client? client, this.endpoint = _defaultEndpoint})
    : _client = client ?? http.Client();

  static const _defaultEndpoint = 'https://graphql.anilist.co';
  static const _query = r'''
query ($search: String!, $perPage: Int!) {
  Page(perPage: $perPage) {
    media(search: $search, type: ANIME, sort: SEARCH_MATCH) {
      id
      type
      format
      isAdult
      episodes
      duration
      seasonYear
      title { romaji english native }
      description(asHtml: false)
      coverImage { large medium }
      bannerImage
      trailer { id site }
      characters(sort: ROLE, perPage: 8) {
        edges {
          role
          node { id name { full } image { medium } }
          voiceActors(language: JAPANESE) {
            id
            name { full }
            image { medium }
          }
        }
      }
      staff(sort: RELEVANCE, perPage: 8) {
        edges {
          role
          node { id name { full } image { medium } }
        }
      }
      genres
      synonyms
    }
  }
}
''';

  final http.Client _client;
  final String endpoint;

  @override
  String get provider => 'anilist';

  @override
  Future<List<VideoProviderCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) return const [];
    final boundedLimit = limit.clamp(1, 50);
    final response = await _request(
      _client.post(
        Uri.parse(endpoint),
        headers: const {
          'accept': 'application/json',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'query': _query,
          'variables': {'search': normalizedQuery, 'perPage': boundedLimit},
        }),
      ),
    );
    final data = _decodeObject(response, provider);
    final dataValue = data['data'];
    final page = dataValue is Map ? dataValue['Page'] : null;
    final media = page is Map ? page['media'] : null;
    if (media is! List) return const [];
    final candidates = <VideoProviderCandidate>[];
    for (final value in media) {
      if (value is! Map) continue;
      final candidate = _candidate(value, language: language);
      if (candidate != null) candidates.add(candidate);
    }
    return candidates;
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw VideoProviderException(provider, 'Zeitüberschreitung');
    } on Object {
      throw VideoProviderException(provider, 'Netzwerkanfrage fehlgeschlagen');
    }
  }

  VideoProviderCandidate? _candidate(Map value, {String? language}) {
    final id = value['id'];
    final titles = value['title'];
    if (id is! num || titles is! Map) return null;
    final title = _firstString(
      language?.toLowerCase().startsWith('ja') == true
          ? [titles['native'], titles['romaji'], titles['english']]
          : [titles['english'], titles['romaji'], titles['native']],
    );
    if (title == null) return null;
    final alternateTitles = <String>{
      for (final candidate in [
        titles['english'],
        titles['romaji'],
        titles['native'],
        ...(value['synonyms'] is List ? value['synonyms'] as List : const []),
      ])
        if (candidate is String && candidate.trim().isNotEmpty)
          candidate.trim(),
    }..remove(title);
    final format = value['format'];
    final isAdult = value['isAdult'] == true;
    final credits = _credits(value);
    final trailer = value['trailer'];
    final trailerUrl = trailer is Map && trailer['site'] == 'youtube'
        ? 'https://www.youtube.com/watch?v=${trailer['id']}'
        : null;
    return VideoProviderCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title,
      alternateTitles: alternateTitles.toList(growable: false),
      videoKind: format == 'MOVIE' ? 'movie' : 'tv',
      contentStyle: 'anime',
      contentSensitivity: isAdult ? 'adult_explicit' : null,
      releaseYear: (value['seasonYear'] as num?)?.round(),
      runtimeMinutes: (value['duration'] as num?)?.round(),
      episodeCount: (value['episodes'] as num?)?.round(),
      isAdult: isAdult,
      description: _cleanDescription(value['description']),
      genres: value['genres'] is List
          ? (value['genres'] as List).whereType<String>().toList(
              growable: false,
            )
          : const [],
      posterUrl:
          _stringFromMap(value['coverImage'], 'large') ??
          _stringFromMap(value['coverImage'], 'medium'),
      backdropUrl: value['bannerImage'] as String?,
      credits: credits,
      trailerUrl: trailerUrl,
      externalIds: {'anilist': '${id.round()}'},
    );
  }

  List<VideoProviderCredit> _credits(Map value) {
    final result = <VideoProviderCredit>[];
    final seen = <String>{};
    void add(Object? raw, {String? role}) {
      if (raw is! Map) return;
      final name = _stringFromMap(raw['name'], 'full')?.trim();
      if (name == null || name.isEmpty || !seen.add(name.toLowerCase())) {
        return;
      }
      final id = raw['id'];
      result.add(
        VideoProviderCredit(
          name: name,
          role: role,
          providerId: id is num ? '${id.round()}' : null,
          imageUrl: _stringFromMap(raw['image'], 'medium'),
        ),
      );
    }

    final characters = value['characters'];
    if (characters is Map && characters['edges'] is List) {
      for (final edge in characters['edges'] as List) {
        if (edge is! Map) continue;
        final character = edge['node'];
        final characterName = _stringFromMap(character?['name'], 'full');
        final voiceActors = edge['voiceActors'];
        if (voiceActors is List && voiceActors.isNotEmpty) {
          for (final actor in voiceActors) {
            add(
              actor,
              role: characterName == null
                  ? 'Stimme'
                  : '$characterName · Stimme',
            );
          }
        } else {
          add(character, role: edge['role'] as String?);
        }
      }
    }
    final staff = value['staff'];
    if (staff is Map && staff['edges'] is List) {
      for (final edge in staff['edges'] as List) {
        if (edge is Map) add(edge['node'], role: edge['role'] as String?);
      }
    }
    return result;
  }
}

/// TMDB adapter for regular movies and TV. The key is supplied at runtime and
/// is never serialized, logged or included in exception messages.
final class TmdbVideoProvider implements VideoMetadataProvider {
  TmdbVideoProvider({required this.apiKey, http.Client? client})
    : _client = client ?? http.Client();

  static const _endpoint = 'https://api.themoviedb.org/3/search/multi';
  static const _detailsEndpoint = 'https://api.themoviedb.org/3';
  final String apiKey;
  final http.Client _client;

  @override
  String get provider => 'tmdb';

  @override
  Future<List<VideoProviderCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty || apiKey.trim().isEmpty) return const [];
    final response = await _request(
      _client.get(
        Uri.parse(_endpoint).replace(
          queryParameters: {
            'api_key': apiKey,
            'query': normalizedQuery,
            'include_adult': 'false',
            'language': language?.trim().isNotEmpty == true
                ? language!.trim()
                : 'de-DE',
          },
        ),
        headers: const {'accept': 'application/json'},
      ),
    );
    final data = _decodeObject(response, provider);
    final results = data['results'];
    if (results is! List) return const [];
    final candidates = <VideoProviderCandidate>[];
    for (final value in results.take(limit.clamp(1, 50))) {
      if (value is Map) {
        final candidate = _candidate(value, language: language);
        if (candidate == null) continue;
        candidates.add(candidate);
      }
    }
    // Details requests are independent. Fetch them concurrently so a result
    // list does not incur one full network round-trip per title.
    return Future.wait(
      candidates.map(
        (candidate) async =>
            await _loadDetails(candidate, language: language) ?? candidate,
      ),
    );
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(const Duration(seconds: 12));
    } on TimeoutException {
      throw VideoProviderException(provider, 'Zeitüberschreitung');
    } on Object {
      throw VideoProviderException(provider, 'Netzwerkanfrage fehlgeschlagen');
    }
  }

  VideoProviderCandidate? _candidate(Map value, {String? language}) {
    final id = value['id'];
    final mediaType = value['media_type'];
    if (id is! num || (mediaType != 'movie' && mediaType != 'tv')) return null;
    final title = _firstString([
      mediaType == 'movie' ? value['title'] : value['name'],
      mediaType == 'movie' ? value['original_title'] : value['original_name'],
    ]);
    if (title == null) return null;
    final alternate = _firstString([
      mediaType == 'movie' ? value['original_title'] : value['original_name'],
    ]);
    final date = _firstString([
      mediaType == 'movie' ? value['release_date'] : value['first_air_date'],
    ]);
    final isAdult = value['adult'] == true;
    return VideoProviderCandidate(
      provider: provider,
      providerId: '${id.round()}',
      title: title,
      alternateTitles: alternate == null || alternate == title
          ? const []
          : [alternate],
      videoKind: mediaType,
      contentSensitivity: isAdult ? 'adult_explicit' : null,
      releaseYear: int.tryParse(date?.split('-').first ?? ''),
      isAdult: isAdult,
      description: _cleanDescription(value['overview']),
      posterUrl: _imageUrl(value['poster_path'], 'w500'),
      backdropUrl: _imageUrl(value['backdrop_path'], 'w1280'),
      externalIds: {'tmdb': '${id.round()}'},
    );
  }

  Future<VideoProviderCandidate?> _loadDetails(
    VideoProviderCandidate candidate, {
    String? language,
  }) async {
    final kind = candidate.videoKind;
    if (kind != 'movie' && kind != 'tv') return null;
    final endpoint = '$_detailsEndpoint/$kind/${candidate.providerId}';
    try {
      final response = await _request(
        _client.get(
          Uri.parse(endpoint).replace(
            queryParameters: {
              'api_key': apiKey,
              'language': language?.trim().isNotEmpty == true
                  ? language!.trim()
                  : 'de-DE',
              'append_to_response': 'credits,videos',
            },
          ),
          headers: const {'accept': 'application/json'},
        ),
      );
      final value = _decodeObject(response, provider);
      return _mergeDetails(candidate, value);
    } on Object {
      // Search results remain useful when a provider disallows a details
      // request, is rate limited, or the item was removed in the meantime.
      return null;
    }
  }

  VideoProviderCandidate _mergeDetails(VideoProviderCandidate base, Map value) {
    final credits = <VideoProviderCredit>[];
    final seen = <String>{};
    void add(Object? raw, {String? role}) {
      if (raw is! Map || raw['name'] is! String) return;
      final name = (raw['name'] as String).trim();
      if (name.isEmpty || !seen.add(name.toLowerCase())) return;
      final id = raw['id'];
      final imagePath = raw['profile_path'];
      credits.add(
        VideoProviderCredit(
          name: name,
          role: role,
          providerId: id is num ? '${id.round()}' : null,
          imageUrl: imagePath is String && imagePath.isNotEmpty
              ? 'https://image.tmdb.org/t/p/w185$imagePath'
              : null,
        ),
      );
    }

    final creditValue = value['credits'];
    if (creditValue is Map) {
      final cast = creditValue['cast'];
      if (cast is List) {
        for (final item in cast.take(12)) {
          if (item is Map) add(item, role: item['character'] as String?);
        }
      }
      final crew = creditValue['crew'];
      if (crew is List) {
        for (final item in crew.take(16)) {
          if (item is Map) {
            final job = item['job'] as String? ?? item['department'] as String?;
            if (job == 'Director' || job == 'Writer' || job == 'Screenplay') {
              add(item, role: job);
            }
          }
        }
      }
    }

    String? trailerUrl;
    final videoValue = value['videos'];
    final videoResults = videoValue is Map ? videoValue['results'] : null;
    if (videoResults is List) {
      for (final item in videoResults) {
        if (item is! Map || item['site'] != 'YouTube') continue;
        final type = item['type'];
        if (type != 'Trailer' && type != 'Teaser') continue;
        final key = item['key'];
        if (key is String && key.trim().isNotEmpty) {
          trailerUrl = 'https://www.youtube.com/watch?v=${key.trim()}';
          break;
        }
      }
    }

    final detailGenres = value['genres'];
    final genres = detailGenres is List
        ? detailGenres
              .whereType<Map>()
              .map((item) => item['name'])
              .whereType<String>()
              .where((name) => name.trim().isNotEmpty)
              .map((name) => name.trim())
              .toList(growable: false)
        : base.genres;
    final runtime = value['runtime'] is num
        ? (value['runtime'] as num).round()
        : value['episode_run_time'] is List &&
              (value['episode_run_time'] as List).isNotEmpty &&
              (value['episode_run_time'] as List).first is num
        ? ((value['episode_run_time'] as List).first as num).round()
        : base.runtimeMinutes;
    final episodes = value['number_of_episodes'] is num
        ? (value['number_of_episodes'] as num).round()
        : base.episodeCount;
    final date = value['release_date'] ?? value['first_air_date'];
    final year = date is String
        ? int.tryParse(date.split('-').first)
        : base.releaseYear;
    return VideoProviderCandidate(
      provider: base.provider,
      providerId: base.providerId,
      title: _firstString([value['title'], value['name']]) ?? base.title,
      alternateTitles: base.alternateTitles,
      videoKind: base.videoKind,
      contentStyle: base.contentStyle,
      contentSensitivity: base.contentSensitivity,
      releaseYear: year,
      runtimeMinutes: runtime,
      season: base.season,
      episodeCount: episodes,
      isAdult: value['adult'] is bool ? value['adult'] as bool : base.isAdult,
      description: _cleanDescription(value['overview']) ?? base.description,
      genres: genres,
      posterUrl: _imageUrl(value['poster_path'], 'w500') ?? base.posterUrl,
      backdropUrl:
          _imageUrl(value['backdrop_path'], 'w1280') ?? base.backdropUrl,
      credits: credits.isEmpty ? base.credits : credits,
      trailerUrl: trailerUrl ?? base.trailerUrl,
      externalIds: base.externalIds,
    );
  }
}

Map<String, Object?> _decodeObject(http.Response response, String provider) {
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw VideoProviderException(
      provider,
      'Provider antwortete mit einem Fehler',
    );
  }
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException();
    }
    if (decoded['errors'] is List && (decoded['errors'] as List).isNotEmpty) {
      throw VideoProviderException(provider, 'Providerantwort ist ungültig');
    }
    return Map<String, Object?>.from(decoded);
  } on VideoProviderException {
    rethrow;
  } on Object {
    throw VideoProviderException(provider, 'Providerantwort ist ungültig');
  }
}

String? _firstString(Iterable<Object?> values) {
  for (final value in values) {
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

String? _stringFromMap(Object? value, String key) =>
    value is Map && value[key] is String ? (value[key] as String).trim() : null;

String? _cleanDescription(Object? value) {
  if (value is! String) return null;
  final clean = value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return clean.isEmpty ? null : clean;
}

String? _imageUrl(Object? path, String size) =>
    path is String && path.isNotEmpty
    ? 'https://image.tmdb.org/t/p/$size$path'
    : null;
