import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/video_track_preferences.dart';

void main() {
  test('an unset subtitle preference survives serialization as unset', () {
    const preference = VideoTrackPreference(audioLanguage: 'de');

    expect(preference.toJson(), {'audio_language': 'de'});
    expect(
      VideoTrackPreference.fromJson(preference.toJson()).subtitlesEnabled,
      isNull,
    );
  });

  test(
    'explicit subtitle off remains distinguishable from inherited value',
    () {
      const preference = VideoTrackPreference(subtitlesEnabled: false);

      expect(preference.toJson()['subtitles_enabled'], isFalse);
      expect(
        VideoTrackPreference.fromJson(preference.toJson()).subtitlesEnabled,
        isFalse,
      );
    },
  );

  test('clearing an override returns to the parent hierarchy', () {
    const preference = VideoTrackPreference(
      audioLanguage: 'de',
      subtitlesEnabled: true,
    );

    final cleared = preference.copyWith(
      clearAudio: true,
      clearSubtitlesEnabled: true,
    );

    expect(cleared.audioLanguage, isNull);
    expect(cleared.subtitlesEnabled, isNull);
    expect(cleared.toJson(), isEmpty);
  });

  test('portable profile layers work, season and file overrides', () {
    final profile = VideoTrackPreferences.updatePortableProfile(
      null,
      const VideoTrackPreference(audioLanguage: 'de'),
    );
    final withSeason = VideoTrackPreferences.updatePortableProfile(
      profile,
      const VideoTrackPreference(
        subtitlesEnabled: true,
        subtitleLanguage: 'en',
      ),
      season: 2,
    );
    final withFile = VideoTrackPreferences.updatePortableProfile(
      withSeason,
      const VideoTrackPreference(audioLanguage: 'ja'),
      season: 2,
      fileId: 'episode-7',
    );

    final result = VideoTrackPreferences.overlayPortableProfile(
      const VideoTrackPreference(),
      withFile,
      season: 2,
      fileId: 'episode-7',
    );
    expect(result.audioLanguage, 'ja');
    expect(result.subtitleLanguage, 'en');
    expect(result.subtitlesEnabled, isTrue);
  });

  test('portable profile keeps unrelated file overrides', () {
    final first = VideoTrackPreferences.updatePortableProfile(
      null,
      const VideoTrackPreference(audioLanguage: 'de'),
      fileId: 'one',
    );
    final second = VideoTrackPreferences.updatePortableProfile(
      first,
      const VideoTrackPreference(audioLanguage: 'en'),
      fileId: 'two',
    );

    final one = VideoTrackPreferences.overlayPortableProfile(
      const VideoTrackPreference(),
      second,
      fileId: 'one',
    );
    expect(one.audioLanguage, 'de');
  });

  test('video preference levels inherit broad defaults in stable order', () {
    expect(VideoTrackPreferences.preferenceLevels('movie'), ['video', 'movie']);
    expect(VideoTrackPreferences.preferenceLevels('tv'), ['video', 'tv']);
    expect(VideoTrackPreferences.preferenceLevels('anime_tv'), [
      'video',
      'tv',
      'anime_tv',
    ]);
    expect(VideoTrackPreferences.preferenceLevels('hhh_movie'), [
      'video',
      'movie',
      'hhh_movie',
    ]);
  });

  test('variant preferences do not overwrite the base media type', () async {
    VideoTrackPreferences.clearCache();
    await VideoTrackPreferences.save(
      kind: 'tv',
      preference: const VideoTrackPreference(audioLanguage: 'de'),
    );
    await VideoTrackPreferences.save(
      kind: 'anime_tv',
      preference: const VideoTrackPreference(audioLanguage: 'ja'),
    );

    expect((await VideoTrackPreferences.load(kind: 'tv')).audioLanguage, 'de');
    expect(
      (await VideoTrackPreferences.load(kind: 'anime_tv')).audioLanguage,
      'ja',
    );
  });
}
