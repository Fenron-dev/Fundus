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

  test('does not classify movie filenames as episodes', () {
    expect(parseVideoEpisode('Star Wars Episode IV.mkv'), isNull);
  });
}
