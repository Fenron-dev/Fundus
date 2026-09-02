import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('parses SxxExx episode names and keeps a readable title', () {
    final episode = parseVideoEpisode(
      'Firefly - S01E02 - The Train Job.1080p.mkv',
    );

    expect(episode?.season, 1);
    expect(episode?.episode, 2);
    expect(episode?.label, 'S01E02');
    expect(episode?.title, 'Firefly - The Train Job 1080p');
  });

  test('parses compact season x episode notation', () {
    final episode = parseVideoEpisode('Show 2x7.mp4');

    expect(episode?.season, 2);
    expect(episode?.episode, 7);
  });

  test('parses multiple episodes and marks season zero specials', () {
    final episode = parseVideoEpisode('Show - S00E01-E02 - Special.mkv');

    expect(episode?.special, isTrue);
    expect(episode?.episodeEnd, 2);
    expect(episode?.label, 'S00E01-E02');
  });

  test('parses conservative absolute anime episode numbering', () {
    final episode = parseVideoEpisode('Show - 001 - The Beginning.mkv');

    expect(episode?.absoluteEpisode, 1);
    expect(episode?.episode, 1);
    expect(episode?.label, 'E001');
    expect(episode?.title, 'Show - The Beginning');
  });

  test('parses explicit episode markers without classifying years', () {
    expect(parseVideoEpisode('Show (2024) 1080p.mkv'), isNull);
    final episode = parseVideoEpisode('Show Episode 12 - Finale.mkv');

    expect(episode?.absoluteEpisode, 12);
    expect(episode?.label, 'E012');
  });

  test('does not classify movie filenames as episodes', () {
    expect(parseVideoEpisode('Star Wars Episode IV.mkv'), isNull);
  });

  test('serializes episode identity for remote clients', () {
    final original = parseVideoEpisode(
      'Firefly - S01E02-E03 - The Train Job.mkv',
    )!;
    final restored = videoEpisodeFromJson(videoEpisodeToJson(original));

    expect(restored?.season, original.season);
    expect(restored?.episode, original.episode);
    expect(restored?.label, original.label);
    expect(restored?.title, original.title);
    expect(restored?.episodeEnd, 3);
  });

  test('ignores malformed episode identity payloads', () {
    expect(videoEpisodeFromJson({'season': '1', 'episode': 2}), isNull);
    expect(videoEpisodeFromJson(null), isNull);
  });

  test('ranks provider candidates using alternate titles', () {
    final matches = rankVideoProviderMatches('Star Wars', [
      const VideoProviderCandidate(
        provider: 'tmdb',
        providerId: '11',
        title: 'Krieg der Sterne',
        alternateTitles: ['Star Wars'],
      ),
      const VideoProviderCandidate(
        provider: 'tmdb',
        providerId: '12',
        title: 'Star Trek',
      ),
    ]);

    expect(matches.first.candidate.providerId, '11');
    expect(matches.first.score, 1);
    expect(matches.first.needsConfirmation, isFalse);
  });

  test('provider candidate JSON is portable and ignores malformed values', () {
    const candidate = VideoProviderCandidate(
      provider: 'anilist',
      providerId: '42',
      title: 'Cowboy Bebop',
      releaseYear: 1998,
      isAdult: false,
      genres: ['Action', 'Science Fiction'],
      externalIds: {'mal': '1'},
    );
    final restored = VideoProviderCandidate.fromJson(candidate.toJson());

    expect(restored?.provider, 'anilist');
    expect(restored?.releaseYear, 1998);
    expect(restored?.genres, ['Action', 'Science Fiction']);
    expect(restored?.externalIds['mal'], '1');
    expect(VideoProviderCandidate.fromJson({'title': 'unvollständig'}), isNull);
  });
}
