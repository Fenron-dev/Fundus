import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:http/http.dart' as http;

import 'package:fundus/video/video_metadata_provider.dart';

void main() {
  test('AniList maps alternate titles and adult sensitivity', () async {
    final client = _StubClient(
      jsonEncode({
        'data': {
          'Page': {
            'media': [
              {
                'id': 42,
                'format': 'TV',
                'isAdult': true,
                'episodes': 12,
                'duration': 24,
                'seasonYear': 2025,
                'title': {
                  'romaji': 'Secret Title',
                  'english': 'A Secret Title',
                  'native': '秘密',
                },
                'synonyms': ['Hidden Title'],
                'description': '<b>Short</b> description',
                'genres': ['Action', 'Comedy'],
                'coverImage': {'large': 'https://img.example/cover.webp'},
                'bannerImage': 'https://img.example/banner.webp',
                'trailer': {'id': 'abc123', 'site': 'youtube'},
                'characters': {
                  'edges': [
                    {
                      'role': 'MAIN',
                      'node': {
                        'id': 77,
                        'name': {'full': 'Mika Hero'},
                        'image': {'medium': 'https://img.example/mika.webp'},
                      },
                      'voiceActors': [
                        {
                          'id': 88,
                          'name': {'full': 'Jane Voice'},
                          'image': {'medium': 'https://img.example/jane.webp'},
                        },
                      ],
                    },
                  ],
                },
                'staff': {
                  'edges': [
                    {
                      'role': 'Director',
                      'node': {
                        'id': 99,
                        'name': {'full': 'Pat Director'},
                        'image': {'medium': 'https://img.example/pat.webp'},
                      },
                    },
                  ],
                },
              },
            ],
          },
        },
      }),
    );
    final results = await AniListVideoProvider(client: client).search('secret');

    expect(results, hasLength(1));
    expect(results.single.providerId, '42');
    expect(results.single.title, 'A Secret Title');
    expect(results.single.alternateTitles, containsAll(['Secret Title', '秘密']));
    expect(results.single.contentSensitivity, 'adult_explicit');
    expect(results.single.runtimeMinutes, 24);
    expect(results.single.description, 'Short description');
    expect(results.single.genres, ['Action', 'Comedy']);
    expect(results.single.trailerUrl, 'https://www.youtube.com/watch?v=abc123');
    expect(results.single.credits, hasLength(2));
    expect(results.single.credits[0].name, 'Jane Voice');
    expect(results.single.credits[0].role, 'Mika Hero · Stimme');
    expect(results.single.credits[1].name, 'Pat Director');
    expect(results.single.credits[1].role, 'Director');
    expect(client.lastRequest?.url.toString(), 'https://graphql.anilist.co');
  });

  test('TMDB maps movies and never sends an empty key', () async {
    final empty = _StubClient('{}');
    expect(
      await TmdbVideoProvider(apiKey: '', client: empty).search('film'),
      isEmpty,
    );
    expect(empty.lastRequest, isNull);

    final client = _StubClient(
      jsonEncode({
        'results': [
          {
            'id': 7,
            'media_type': 'movie',
            'adult': false,
            'title': 'Der Film',
            'original_title': 'The Film',
            'release_date': '2024-03-01',
            'overview': 'Eine Beschreibung',
            'poster_path': '/poster.jpg',
            'backdrop_path': '/backdrop.jpg',
          },
        ],
      }),
    );
    final results = await TmdbVideoProvider(
      apiKey: 'runtime-only-key',
      client: client,
    ).search('film');

    expect(results.single.videoKind, 'movie');
    expect(results.single.releaseYear, 2024);
    expect(results.single.alternateTitles, ['The Film']);
    expect(
      results.single.posterUrl,
      'https://image.tmdb.org/t/p/w500/poster.jpg',
    );
    expect(
      client.lastRequest?.url.queryParameters['api_key'],
      'runtime-only-key',
    );
  });

  test('TMDB enriches a result with credits and trailer details', () async {
    final client = _SequenceClient([
      jsonEncode({
        'results': [
          {
            'id': 7,
            'media_type': 'movie',
            'title': 'Der Film',
            'release_date': '2024-03-01',
          },
        ],
      }),
      jsonEncode({
        'id': 7,
        'title': 'Der Film',
        'runtime': 101,
        'overview': 'Beschreibung',
        'genres': [
          {'name': 'Action'},
        ],
        'credits': {
          'cast': [
            {
              'id': 88,
              'name': 'Jane Voice',
              'character': 'Alex',
              'profile_path': '/jane.jpg',
            },
          ],
          'crew': [
            {'id': 99, 'name': 'Pat Director', 'job': 'Director'},
          ],
        },
        'videos': {
          'results': [
            {'site': 'YouTube', 'type': 'Trailer', 'key': 'abc123'},
          ],
        },
      }),
    ]);

    final result = (await TmdbVideoProvider(
      apiKey: 'runtime-only-key',
      client: client,
    ).search('film')).single;

    expect(result.runtimeMinutes, 101);
    expect(result.credits, hasLength(2));
    expect(result.credits.first.name, 'Jane Voice');
    expect(result.credits.first.role, 'Alex');
    expect(result.credits.last.name, 'Pat Director');
    expect(result.trailerUrl, 'https://www.youtube.com/watch?v=abc123');
    expect(client.requests, hasLength(2));
    expect(client.requests.last.url.path, '/3/movie/7');
  });

  test('provider errors do not echo credentials', () async {
    final client = _StubClient('{}', statusCode: 500);
    expect(
      () => TmdbVideoProvider(apiKey: 'secret-key', client: client).search('x'),
      throwsA(
        predicate<Object>(
          (error) =>
              error.toString().contains('Provider antwortete') &&
              !error.toString().contains('secret-key'),
        ),
      ),
    );
  });

  test('metadata service ranks results across optional providers', () async {
    final service = VideoMetadataService([
      _StaticProvider([
        const VideoProviderCandidate(
          provider: 'anilist',
          providerId: '1',
          title: 'My Anime',
        ),
      ]),
      _FailingProvider(),
    ]);

    final matches = await service.search('my anime');
    expect(matches, hasLength(1));
    expect(matches.single.candidate.providerId, '1');
    expect(matches.single.score, 1);
  });

  test(
    'metadata service caches successful lookups and shares in-flight work',
    () async {
      VideoMetadataService.clearCache();
      final provider = _CountingProvider();
      final service = VideoMetadataService([
        provider,
      ], cacheTtl: const Duration(minutes: 1));

      final first = service.search('cache regression');
      final second = service.search('cache regression');
      await Future.wait([first, second]);
      await service.search('cache regression');

      expect(provider.calls, 1);
      VideoMetadataService.clearCache();
    },
  );
}

final class _StubClient extends http.BaseClient {
  _StubClient(this.body, {this.statusCode = 200});

  final String body;
  final int statusCode;
  http.BaseRequest? lastRequest;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      statusCode,
      headers: const {'content-type': 'application/json'},
    );
  }
}

final class _SequenceClient extends http.BaseClient {
  _SequenceClient(this.bodies);

  final List<String> bodies;
  final requests = <http.BaseRequest>[];
  var _index = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = bodies[_index < bodies.length ? _index++ : bodies.length - 1];
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

final class _StaticProvider implements VideoMetadataProvider {
  const _StaticProvider(this.values);

  final List<VideoProviderCandidate> values;

  @override
  String get provider => 'static';

  @override
  Future<List<VideoProviderCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async => values;
}

final class _CountingProvider implements VideoMetadataProvider {
  var calls = 0;

  @override
  String get provider => 'counting';

  @override
  Future<List<VideoProviderCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const [
      VideoProviderCandidate(
        provider: 'counting',
        providerId: '1',
        title: 'Cached result',
      ),
    ];
  }
}

final class _FailingProvider implements VideoMetadataProvider {
  @override
  String get provider => 'failing';

  @override
  Future<List<VideoProviderCandidate>> search(
    String query, {
    int limit = 10,
    String? language,
  }) => throw const VideoProviderException('failing', 'offline');
}
