import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../library/publication_reader_settings.dart';

/// Language and subtitle defaults for video playback.
///
/// Preferences are layered: media-type default, series/work override and
/// finally an episode/file override.  This keeps a user's normal language
/// choice stable while still allowing a single episode to differ.
final class VideoTrackPreference {
  const VideoTrackPreference({
    this.audioLanguage,
    this.audioTrackId,
    this.audioTrackTitle,
    this.subtitleLanguage,
    this.subtitleTrackId,
    this.subtitleTrackTitle,
    this.subtitlesEnabled,
  });

  final String? audioLanguage;
  final String? audioTrackId;
  final String? audioTrackTitle;
  final String? subtitleLanguage;
  final String? subtitleTrackId;
  final String? subtitleTrackTitle;

  /// `null` means that this level does not override the parent level.
  /// Keeping the unset state is important for the type → work → season →
  /// episode preference hierarchy.
  final bool? subtitlesEnabled;

  VideoTrackPreference copyWith({
    String? audioLanguage,
    String? audioTrackId,
    String? audioTrackTitle,
    String? subtitleLanguage,
    String? subtitleTrackId,
    String? subtitleTrackTitle,
    bool? subtitlesEnabled,
    bool clearAudio = false,
    bool clearAudioTrackIdentity = false,
    bool clearSubtitleLanguage = false,
    bool clearSubtitleTrackIdentity = false,
    bool clearSubtitlesEnabled = false,
  }) {
    // A language override and a concrete track identity are mutually
    // exclusive. Keeping an older track id here would make the player select
    // that track first and silently ignore the newly preferred language.
    final resetAudioIdentity =
        clearAudio || clearAudioTrackIdentity || audioLanguage != null;
    final resetSubtitleIdentity =
        clearSubtitleLanguage ||
        clearSubtitleTrackIdentity ||
        subtitleLanguage != null;
    return VideoTrackPreference(
      audioLanguage: clearAudio ? null : audioLanguage ?? this.audioLanguage,
      audioTrackId: resetAudioIdentity
          ? audioTrackId
          : audioTrackId ?? this.audioTrackId,
      audioTrackTitle: resetAudioIdentity
          ? audioTrackTitle
          : audioTrackTitle ?? this.audioTrackTitle,
      subtitleLanguage: clearSubtitleLanguage
          ? null
          : subtitleLanguage ?? this.subtitleLanguage,
      subtitleTrackId: resetSubtitleIdentity
          ? subtitleTrackId
          : subtitleTrackId ?? this.subtitleTrackId,
      subtitleTrackTitle: resetSubtitleIdentity
          ? subtitleTrackTitle
          : subtitleTrackTitle ?? this.subtitleTrackTitle,
      subtitlesEnabled: clearSubtitlesEnabled
          ? null
          : subtitlesEnabled ?? this.subtitlesEnabled,
    );
  }

  Map<String, Object?> toJson() => {
    if (audioLanguage != null) 'audio_language': audioLanguage,
    if (audioTrackId != null) 'audio_track_id': audioTrackId,
    if (audioTrackTitle != null) 'audio_track_title': audioTrackTitle,
    if (subtitleLanguage != null) 'subtitle_language': subtitleLanguage,
    if (subtitleTrackId != null) 'subtitle_track_id': subtitleTrackId,
    if (subtitleTrackTitle != null) 'subtitle_track_title': subtitleTrackTitle,
    if (subtitlesEnabled != null) 'subtitles_enabled': subtitlesEnabled,
  };

  factory VideoTrackPreference.fromJson(Object? value) {
    if (value is! Map) return const VideoTrackPreference();
    return VideoTrackPreference(
      audioLanguage: value['audio_language'] as String?,
      audioTrackId: value['audio_track_id'] as String?,
      audioTrackTitle: value['audio_track_title'] as String?,
      subtitleLanguage: value['subtitle_language'] as String?,
      subtitleTrackId: value['subtitle_track_id'] as String?,
      subtitleTrackTitle: value['subtitle_track_title'] as String?,
      subtitlesEnabled: value.containsKey('subtitles_enabled')
          ? value['subtitles_enabled'] == true
          : null,
    );
  }
}

abstract final class VideoTrackPreferences {
  static const _storage = FlutterSecureStorage();
  static const _prefix = 'fundus.video.track_preferences.v1';
  static const _portableReaderKind = 'video-tracks';
  static final Map<String, VideoTrackPreference> _cache = {};

  /// Returns the preference levels from broadest to most specific.
  ///
  /// Keeping this order explicit makes the inheritance contract observable
  /// and ensures that a concrete variant (for example `anime_tv`) can never
  /// overwrite the generic `tv` or `video` default.
  static List<String> preferenceLevels(String kind) =>
      List.unmodifiable(_preferenceKinds(kind));

  /// Clears only the in-memory cache. Persisted secure-store values remain
  /// intact and are reloaded on demand.
  static void clearCache() => _cache.clear();

  static Future<VideoTrackPreference> load({
    required String kind,
    String? workId,
    String? fileId,
    int? season,
  }) async {
    // Read the generic family first, then the concrete variant.  This keeps
    // existing `movie`/`tv` settings as a fallback while allowing e.g.
    // `anime_tv` and `hhh_tv` to diverge without overwriting one another.
    final families = _preferenceKinds(kind);
    final keys = <String>[];
    keys.addAll(families.map(_key));
    if (workId != null) {
      keys.addAll(families.map((family) => _key(family, workId)));
    }
    if (season != null && workId != null) {
      keys.addAll(
        families.map((family) => _key(family, workId, 'season-$season')),
      );
    }
    if (fileId != null) {
      keys.addAll(families.map((family) => _key(family, workId, fileId)));
    }
    var result = const VideoTrackPreference();
    for (final key in keys) {
      final preference = await _read(key);
      if (preference == null) continue;
      result = _merge(result, preference);
    }
    return result;
  }

  static Future<void> save({
    required String kind,
    String? workId,
    String? fileId,
    int? season,
    required VideoTrackPreference preference,
  }) => _write(
    _key(
      // Store the exact level that was edited.  Previously variants were
      // reduced to their base kind here, so Anime-/HHH-specific preferences
      // silently changed the regular series defaults as well.
      kind.trim().toLowerCase(),
      workId,
      fileId ?? (season == null ? null : 'season-$season'),
    ),
    preference,
  );

  /// Loads the secure device preference and overlays the portable preference
  /// stored next to the work.  The sidecar is deliberately work-scoped: it
  /// remains available for offline copies and survives an app reinstall,
  /// while the secure store still provides the fast media-type default.
  static Future<VideoTrackPreference> loadForLibrary({
    required FundusLibrary library,
    required String kind,
    required String workId,
    String? fileId,
    int? season,
  }) async {
    var result = await load(
      kind: kind,
      workId: workId,
      fileId: fileId,
      season: season,
    );
    final profile = await library.loadPortableReaderProfile(
      workId: workId,
      deviceKey: await PublicationReaderSettings.deviceKey(),
      readerKind: _portableReaderKind,
    );
    if (profile == null) return result;
    return overlayPortableProfile(
      result,
      profile,
      fileId: fileId,
      season: season,
    );
  }

  /// Applies a portable profile returned by either a local library sidecar
  /// or the remote reader-settings endpoint.
  static VideoTrackPreference overlayPortableProfile(
    VideoTrackPreference base,
    Map<String, Object?>? profile, {
    String? fileId,
    int? season,
  }) {
    final profiles = profile?['profiles'];
    if (profiles is! Map) return base;
    var result = _merge(base, VideoTrackPreference.fromJson(profiles['work']));
    if (season != null) {
      result = _merge(
        result,
        VideoTrackPreference.fromJson(profiles['season:$season']),
      );
    }
    if (fileId != null) {
      result = _merge(
        result,
        VideoTrackPreference.fromJson(profiles['file:$fileId']),
      );
    }
    return result;
  }

  /// Returns an updated portable profile without mutating the caller's map.
  static Map<String, Object?> updatePortableProfile(
    Map<String, Object?>? existing,
    VideoTrackPreference preference, {
    String? fileId,
    int? season,
  }) {
    final profiles = <String, Object?>{
      if (existing?['profiles'] is Map)
        ...Map<String, Object?>.from(existing!['profiles'] as Map),
    };
    final level = fileId != null
        ? 'file:$fileId'
        : season != null
        ? 'season:$season'
        : 'work';
    profiles[level] = preference.toJson();
    return {'format_version': 1, 'profiles': profiles};
  }

  /// Persists an episode/season preference both in the secure store and in
  /// the work's portable reader-settings sidecar.  Sidecar writes are best
  /// effort so a read-only or remote-mounted library never blocks playback.
  static Future<void> saveForLibrary({
    required FundusLibrary library,
    required String kind,
    required String workId,
    String? fileId,
    int? season,
    required VideoTrackPreference preference,
  }) async {
    await save(
      kind: kind,
      workId: workId,
      fileId: fileId,
      season: season,
      preference: preference,
    );
    if (library.isReadOnly) return;
    try {
      final deviceKey = await PublicationReaderSettings.deviceKey();
      final existing = await library.loadPortableReaderProfile(
        workId: workId,
        deviceKey: deviceKey,
        readerKind: _portableReaderKind,
      );
      await library.savePortableReaderProfile(
        workId: workId,
        deviceKey: deviceKey,
        readerKind: _portableReaderKind,
        profile: updatePortableProfile(
          existing,
          preference,
          fileId: fileId,
          season: season,
        ),
      );
    } catch (_) {
      // Portable preferences are optional and must never prevent playback.
    }
  }

  static VideoTrackPreference _merge(
    VideoTrackPreference parent,
    VideoTrackPreference child,
  ) {
    // Child language settings invalidate a parent track id/title. Otherwise a
    // type-level selection (e.g. English track #2) wins over a work-level
    // language override (e.g. German) because ids are matched first.
    final audioLanguage = child.audioLanguage ?? parent.audioLanguage;
    final subtitleLanguage = child.subtitleLanguage ?? parent.subtitleLanguage;
    return VideoTrackPreference(
      audioLanguage: audioLanguage,
      audioTrackId:
          child.audioTrackId ??
          (child.audioLanguage != null ? null : parent.audioTrackId),
      audioTrackTitle:
          child.audioTrackTitle ??
          (child.audioLanguage != null ? null : parent.audioTrackTitle),
      subtitleLanguage: subtitleLanguage,
      subtitleTrackId:
          child.subtitleTrackId ??
          (child.subtitleLanguage != null ? null : parent.subtitleTrackId),
      subtitleTrackTitle:
          child.subtitleTrackTitle ??
          (child.subtitleLanguage != null ? null : parent.subtitleTrackTitle),
      subtitlesEnabled: child.subtitlesEnabled ?? parent.subtitlesEnabled,
    );
  }

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

  static String _baseKind(String kind) {
    final base = VideoWorkKind.base(kind);
    return base == 'movie' || base == 'tv' ? base : 'video';
  }

  static List<String> _preferenceKinds(String kind) {
    final normalized = kind.trim().toLowerCase();
    final base = _baseKind(normalized);
    final levels = <String>['video'];
    if (base != 'video') levels.add(base);
    if (normalized != base && normalized != 'video') levels.add(normalized);
    return levels.toSet().toList(growable: false);
  }
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
    ('tv', 'Serien'),
    ('anime_movie', 'Anime-Filme'),
    ('anime_tv', 'Anime-Serien'),
    ('hhh_movie', 'HHH-Filme'),
    ('hhh_tv', 'HHH-Serien'),
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
        '${value.subtitlesEnabled == null
            ? 'Automatisch'
            : value.subtitlesEnabled == true
            ? value.subtitleLanguage ?? 'Automatisch'
            : 'Aus'}',
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Voreinstellung ändern',
        onSelected: (selection) async {
          final updated = switch (selection) {
            'de' => value.copyWith(audioLanguage: 'de', subtitleLanguage: 'de'),
            'en' => value.copyWith(audioLanguage: 'en', subtitleLanguage: 'en'),
            'ja' => value.copyWith(audioLanguage: 'ja', subtitleLanguage: 'ja'),
            'subtitles' => value.copyWith(
              subtitlesEnabled: value.subtitlesEnabled != true,
            ),
            _ => value.copyWith(
              clearAudio: true,
              clearSubtitleLanguage: true,
              clearSubtitlesEnabled: true,
            ),
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
              value.subtitlesEnabled == true
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
