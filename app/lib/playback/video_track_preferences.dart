import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Language and subtitle defaults for video playback.
///
/// Preferences are layered: media-type default, series/work override and
/// finally an episode/file override.  This keeps a user's normal language
/// choice stable while still allowing a single episode to differ.
final class VideoTrackPreference {
  const VideoTrackPreference({
    this.audioLanguage,
    this.subtitleLanguage,
    this.subtitlesEnabled = false,
  });

  final String? audioLanguage;
  final String? subtitleLanguage;
  final bool subtitlesEnabled;

  VideoTrackPreference copyWith({
    String? audioLanguage,
    String? subtitleLanguage,
    bool? subtitlesEnabled,
    bool clearAudio = false,
    bool clearSubtitleLanguage = false,
  }) => VideoTrackPreference(
    audioLanguage: clearAudio ? null : audioLanguage ?? this.audioLanguage,
    subtitleLanguage: clearSubtitleLanguage
        ? null
        : subtitleLanguage ?? this.subtitleLanguage,
    subtitlesEnabled: subtitlesEnabled ?? this.subtitlesEnabled,
  );

  Map<String, Object?> toJson() => {
    if (audioLanguage != null) 'audio_language': audioLanguage,
    if (subtitleLanguage != null) 'subtitle_language': subtitleLanguage,
    'subtitles_enabled': subtitlesEnabled,
  };

  factory VideoTrackPreference.fromJson(Object? value) {
    if (value is! Map) return const VideoTrackPreference();
    return VideoTrackPreference(
      audioLanguage: value['audio_language'] as String?,
      subtitleLanguage: value['subtitle_language'] as String?,
      subtitlesEnabled: value['subtitles_enabled'] == true,
    );
  }
}

abstract final class VideoTrackPreferences {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'fundus.video.track_preferences.v1';
  static final Map<String, VideoTrackPreference> _cache = {};

  static Future<VideoTrackPreference> load({
    required String kind,
    String? workId,
    String? fileId,
  }) async {
    final keys = <String>[_key(_baseKind(kind))];
    if (workId != null) keys.add(_key(_baseKind(kind), workId));
    if (fileId != null) keys.add(_key(_baseKind(kind), workId, fileId));
    var result = const VideoTrackPreference();
    for (final key in keys) {
      final preference = await _read(key);
      if (preference == null) continue;
      result = VideoTrackPreference(
        audioLanguage: preference.audioLanguage ?? result.audioLanguage,
        subtitleLanguage:
            preference.subtitleLanguage ?? result.subtitleLanguage,
        subtitlesEnabled: preference.subtitlesEnabled,
      );
    }
    return result;
  }

  static Future<void> save({
    required String kind,
    String? workId,
    String? fileId,
    required VideoTrackPreference preference,
  }) => _write(_key(_baseKind(kind), workId, fileId), preference);

  static Future<VideoTrackPreference?> _read(String key) async {
    if (_cache.containsKey(key)) return _cache[key];
    try {
      final raw = await _storage.read(key: key);
      if (raw == null) return null;
      final value = VideoTrackPreference.fromJson(jsonDecode(raw));
      _cache[key] = value;
      return value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _write(String key, VideoTrackPreference value) async {
    _cache[key] = value;
    try {
      await _storage.write(key: key, value: jsonEncode(value.toJson()));
    } catch (_) {
      // Preferences are optional and must never prevent playback.
    }
  }

  static String _key(String kind, [String? workId, String? fileId]) {
    String safe(String value) =>
        base64Url.encode(utf8.encode(value)).replaceAll('=', '');
    return [
      _prefix,
      kind,
      if (workId != null) safe(workId),
      if (fileId != null) safe(fileId),
    ].join('.');
  }

  static String _baseKind(String kind) => switch (kind) {
    'movie' => 'movie',
    'tv' => 'tv',
    _ => 'video',
  };
}

final class VideoTrackPreferenceSettingTile extends StatefulWidget {
  const VideoTrackPreferenceSettingTile({super.key});

  @override
  State<VideoTrackPreferenceSettingTile> createState() =>
      _VideoTrackPreferenceSettingTileState();
}

final class _VideoTrackPreferenceSettingTileState
    extends State<VideoTrackPreferenceSettingTile> {
  static const _kinds = [
    ('video', 'Videos'),
    ('movie', 'Filme'),
    ('tv', 'Serien und Anime'),
  ];
  final Map<String, VideoTrackPreference> _values = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final entry in _kinds) {
      _values[entry.$1] = await VideoTrackPreferences.load(kind: entry.$1);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.translate_outlined),
            title: Text('Video-Sprache und Untertitel'),
            subtitle: Text(
              'Voreinstellungen je Medientyp. Serie/Werk und einzelne Folgen '
              'können diese Auswahl im Player überschreiben.',
            ),
          ),
          for (final entry in _kinds) _row(entry.$1, entry.$2),
        ],
      ),
    ),
  );

  Widget _row(String kind, String label) {
    final value = _values[kind] ?? const VideoTrackPreference();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      subtitle: Text(
        'Ton: ${value.audioLanguage ?? 'Automatisch'} · Untertitel: '
        '${value.subtitlesEnabled ? value.subtitleLanguage ?? 'Automatisch' : 'Aus'}',
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Voreinstellung ändern',
        onSelected: (selection) async {
          final updated = switch (selection) {
            'de' => value.copyWith(audioLanguage: 'de', subtitleLanguage: 'de'),
            'en' => value.copyWith(audioLanguage: 'en', subtitleLanguage: 'en'),
            'ja' => value.copyWith(audioLanguage: 'ja', subtitleLanguage: 'ja'),
            'subtitles' => value.copyWith(
              subtitlesEnabled: !value.subtitlesEnabled,
            ),
            _ => value.copyWith(clearAudio: true, clearSubtitleLanguage: true),
          };
          await VideoTrackPreferences.save(kind: kind, preference: updated);
          if (mounted) setState(() => _values[kind] = updated);
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'auto',
            child: Text('Automatische Auswahl'),
          ),
          const PopupMenuItem(value: 'de', child: Text('Deutsch bevorzugen')),
          const PopupMenuItem(value: 'en', child: Text('Englisch bevorzugen')),
          const PopupMenuItem(value: 'ja', child: Text('Japanisch bevorzugen')),
          PopupMenuItem(
            value: 'subtitles',
            child: Text(
              value.subtitlesEnabled
                  ? 'Untertitel ausschalten'
                  : 'Untertitel einschalten',
            ),
          ),
        ],
        child: const Icon(Icons.edit_outlined),
      ),
    );
  }
}
