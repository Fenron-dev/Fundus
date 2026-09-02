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
}
