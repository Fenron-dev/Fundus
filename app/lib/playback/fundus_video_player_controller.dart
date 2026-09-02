import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../diagnostics/fundus_diagnostics.dart';
import 'playback_autosave_settings.dart';
import 'video_track_preferences.dart';

/// Local video playback kept separate from the audiobook controller.
///
/// The controller deliberately uses the same media-neutral `MediaPosition`
/// contract as publications and audio, so server synchronization can be added
/// without changing the player UI later.
final class FundusVideoPlayerController extends ChangeNotifier {
  FundusVideoPlayerController() : _player = Player() {
    // Attach the native video output before a medium is opened. Creating it
    // only in the fullscreen route lets audio decode and seek correctly while
    // the resumed video decoder has no texture to render into.
    _videoController = VideoController(_player);
    _subscriptions.addAll([
      _player.stream.playing.listen((value) {
        _playing = value;
        notifyListeners();
        if (!value && !_restoringPosition) unawaited(persist());
      }),
      _player.stream.position.listen((value) {
        _position = value;
        notifyListeners();
        final interval = PlaybackAutosaveSettings.interval(
          _work?.kind ?? 'video',
        );
        if (_playing &&
            !_restoringPosition &&
            interval > Duration.zero &&
            DateTime.now().difference(_lastPersistedAt) >= interval) {
          unawaited(persist());
        }
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
      _player.stream.playlist.listen((playlist) {
        if (_tracks.isEmpty) return;
        final nextIndex = playlist.index.clamp(0, _tracks.length - 1);
        final changedTrack = nextIndex != _currentIndex;
        _currentIndex = nextIndex;
        if (changedTrack && !_restoringPosition) {
          _position = Duration.zero;
        }
        notifyListeners();
      }),
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        unawaited(persist(finished: true));
      }),
      _player.stream.error.listen((value) {
        _error = value;
        notifyListeners();
      }),
      _player.stream.buffering.listen((value) {
        if (!_ready) return;
        unawaited(
          FundusDiagnostics.instance.record('video.buffering_changed', {
            'work_id': _work?.id,
            'file_id': track?.fileId,
            'buffering': value,
            'position_ms': _player.state.position.inMilliseconds,
            'buffer_ms': _player.state.buffer.inMilliseconds,
          }),
        );
      }),
      _player.stream.videoParams.listen((value) {
        if (!_ready || value.w == null || value.h == null) return;
        unawaited(
          FundusDiagnostics.instance.record('video.output_changed', {
            'work_id': _work?.id,
            'file_id': track?.fileId,
            'width': value.w,
            'height': value.h,
            'pixel_format': value.pixelformat,
            'hardware_pixel_format': value.hwPixelformat,
          }),
        );
      }),
    ]);
  }

  final Player _player;
  late final VideoController _videoController;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  FundusLibrary? _library;
  LibraryWorkSummary? _work;
  List<LibraryPlaybackTrack> _tracks = const [];
  int _currentIndex = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime _lastPersistedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _playing = false;
  bool _loading = false;
  bool _ready = false;
  bool _persisting = false;
  bool _restoringPosition = false;
  bool _closed = false;
  String? _error;

  Player get player => _player;
  VideoController get videoController => _videoController;
  LibraryWorkSummary? get work => _work;
  List<LibraryPlaybackTrack> get tracks => List.unmodifiable(_tracks);
  LibraryPlaybackTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  int get currentIndex => _currentIndex;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> open(
    FundusLibrary library,
    LibraryWorkSummary work, {
    String? startFileId,
    Duration? startPosition,
    bool autoPlay = true,
  }) async {
    if (_closed) return;
    await persist();
    _loading = true;
    _ready = false;
    _error = null;
    _library = library;
    _work = work;
    _tracks = library
        .playbackTracks(work.id)
        .where(isVideoTrack)
        .toList(growable: false);
    _currentIndex = 0;
    _position = Duration.zero;
    _duration = Duration.zero;
    final progress = library.loadProgress(work.id);
    final targetFileId = startFileId ?? progress?.fileId;
    if (targetFileId != null) {
      final index = _tracks.indexWhere((item) => item.fileId == targetFileId);
      if (index >= 0) _currentIndex = index;
    }
    notifyListeners();
    if (_tracks.isEmpty) {
      _loading = false;
      _error = 'Für dieses Werk wurden keine Videodateien gefunden.';
      notifyListeners();
      return;
    }
    final resume =
        startPosition ??
        (progress?.position.kind == MediaPositionKind.time &&
                progress?.fileId == _tracks[_currentIndex].fileId
            ? Duration(
                milliseconds: ((progress?.position.numericValue ?? 0) * 1000)
                    .round(),
              )
            : Duration.zero);
    try {
      _restoringPosition = true;
      await _player.open(
        Playlist([
          for (var index = 0; index < _tracks.length; index++)
            Media(_tracks[index].absolutePath),
        ], index: _currentIndex),
        play: false,
      );
      _ready = true;
      _loading = false;
      _lastPersistedAt = DateTime.now();
      notifyListeners();
      final trackPreference = await VideoTrackPreferences.load(
        kind: work.kind,
        workId: work.id,
        fileId: track?.fileId,
      );
      unawaited(
        FundusDiagnostics.instance.record('video.resume_loaded', {
          'work_id': work.id,
          'file_id': _tracks[_currentIndex].fileId,
          'saved_file_id': progress?.fileId,
          'target_ms': resume.inMilliseconds,
          'revision': progress?.revision,
        }),
      );
      // Apply stream selection while playback is still paused. Reconfiguring
      // the audio/subtitle decoder and seeking an already running MKV can
      // leave the native video output stalled while audio keeps advancing.
      await _applyTrackPreference(trackPreference);
      // Seek only after the container and its selected streams are ready. The
      // Media.start hint is intentionally avoided here: on resumed files it
      // can position the audio decoder while leaving the video texture on a
      // black frame. An explicit paused seek primes both decoders reliably.
      if (resume > Duration.zero) {
        final nativeDuration = _player.state.duration;
        final target = nativeDuration > Duration.zero && resume > nativeDuration
            ? nativeDuration
            : resume;
        await _player.seek(target);
        _position = target;
      } else {
        _position = Duration.zero;
      }
      notifyListeners();
      _restoringPosition = false;
      _lastPersistedAt = DateTime.now();
      if (autoPlay) await _player.play();
      unawaited(_recordNativeResume(resume));
    } catch (error) {
      _restoringPosition = false;
      _loading = false;
      _ready = false;
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> persist({bool finished = false}) async {
    if (!_ready ||
        _restoringPosition ||
        _persisting ||
        _library == null ||
        track == null) {
      return;
    }
    final playerPosition = _player.state.position;
    if (playerPosition > Duration.zero || _position == Duration.zero) {
      _position = playerPosition;
    }
    _persisting = true;
    final write = Stopwatch()..start();
    try {
      final current = track!;
      final position = MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: _position.inMilliseconds / 1000,
        total: _duration > Duration.zero
            ? _duration.inMilliseconds / 1000
            : null,
        fileId: current.fileId,
        label: current.title,
      );
      _library!.saveMediaProgress(
        workId: _work!.id,
        fileId: current.fileId,
        position: position,
        finished: finished,
      );
      _lastPersistedAt = DateTime.now();
      unawaited(
        FundusDiagnostics.instance.record('video.progress_saved', {
          'work_id': _work!.id,
          'file_id': current.fileId,
          'position_ms': _position.inMilliseconds,
          'duration_ms': _duration.inMilliseconds,
          'write_duration_ms': write.elapsedMilliseconds,
          'network_volume': _library!.root.path.startsWith('/Volumes/'),
          'finished': finished,
        }),
      );
    } finally {
      _persisting = false;
    }
  }

  Future<void> toggle() => _playing ? pause() : play();

  Future<void> play() => _player.play();

  Future<void> pause() async {
    await _player.pause();
    await persist();
  }

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> next() => _player.next();

  Future<void> previous() => _player.previous();

  /// Adds a timestamp bookmark for the currently playing episode. This is
  /// also used by the video screenshot action so the captured frame can be
  /// revisited from the work details.
  Future<WorkAnnotations?> addBookmarkAtCurrent({
    String? label,
    String? note,
  }) async {
    final library = _library;
    final work = _work;
    final current = track;
    if (library == null || work == null || current == null || !_ready)
      return null;
    return library.addBookmark(
      workId: work.id,
      fileId: current.fileId,
      position: _position,
      label: label,
      note: note,
    );
  }

  Future<void> rememberAudioTrack(AudioTrack selected) async {
    final work = _work;
    final current = track;
    if (work == null || current == null) return;
    final preference = await VideoTrackPreferences.load(
      kind: work.kind,
      workId: work.id,
      fileId: current.fileId,
    );
    await VideoTrackPreferences.save(
      kind: work.kind,
      workId: work.id,
      fileId: current.fileId,
      preference: preference.copyWith(
        audioLanguage: selected.language,
        audioTrackId: selected.id,
        audioTrackTitle: selected.title,
      ),
    );
  }

  Future<void> rememberSubtitlePreference({
    required bool enabled,
    SubtitleTrack? selected,
  }) async {
    final work = _work;
    final current = track;
    if (work == null || current == null) return;
    final preference = await VideoTrackPreferences.load(
      kind: work.kind,
      workId: work.id,
      fileId: current.fileId,
    );
    await VideoTrackPreferences.save(
      kind: work.kind,
      workId: work.id,
      fileId: current.fileId,
      preference: preference.copyWith(
        subtitlesEnabled: enabled,
        subtitleLanguage: selected?.language,
        subtitleTrackId: selected?.id,
        subtitleTrackTitle: selected?.title,
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    await persist();
    await _player.pause();
    _ready = false;
  }

  Future<void> _recordNativeResume(Duration target) async {
    if (target <= Duration.zero) return;
    await Future<void>.delayed(const Duration(milliseconds: 750));
    if (_closed || track == null) return;
    await FundusDiagnostics.instance.record('video.resume_started', {
      'work_id': _work?.id,
      'file_id': track?.fileId,
      'target_ms': target.inMilliseconds,
      'actual_ms': _player.state.position.inMilliseconds,
      'duration_ms': _player.state.duration.inMilliseconds,
      'buffering': _player.state.buffering,
    });
  }

  Future<void> _applyTrackPreference(VideoTrackPreference preference) async {
    // Track metadata is populated asynchronously by media-kit after opening
    // the container. Give it a short window before applying the persisted
    // selection, while leaving the player's automatic choice as fallback.
    for (var attempt = 0; attempt < 8; attempt++) {
      final tracks = _player.state.tracks;
      final audio = _findAudioTrack(tracks.audio, preference);
      final subtitles = _findSubtitleTrack(tracks.subtitle, preference);
      if (audio != null) await _player.setAudioTrack(audio);
      if (!preference.subtitlesEnabled) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else if (subtitles != null) {
        await _player.setSubtitleTrack(subtitles);
      }
      final needsAudio =
          preference.audioTrackId != null ||
          preference.audioTrackTitle != null ||
          preference.audioLanguage != null;
      final needsSubtitle =
          preference.subtitlesEnabled &&
          (preference.subtitleTrackId != null ||
              preference.subtitleTrackTitle != null ||
              preference.subtitleLanguage != null);
      if ((!needsAudio || audio != null) &&
          (!needsSubtitle || subtitles != null)) {
        unawaited(
          FundusDiagnostics.instance.record('video.track_preferences_applied', {
            'work_id': _work?.id,
            'file_id': track?.fileId,
            'audio_language': audio?.language,
            'audio_track_id': audio?.id,
            'subtitle_language': subtitles?.language,
            'subtitle_track_id': subtitles?.id,
            'subtitles_enabled': preference.subtitlesEnabled,
          }),
        );
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  AudioTrack? _findAudioTrack(
    List<AudioTrack> tracks,
    VideoTrackPreference preference,
  ) {
    for (final item in tracks) {
      if (preference.audioTrackId != null &&
          item.id == preference.audioTrackId) {
        return item;
      }
    }
    final wantedTitle = _normalizeTitle(preference.audioTrackTitle);
    if (wantedTitle != null) {
      for (final item in tracks) {
        if (_normalizeTitle(item.title) == wantedTitle) return item;
      }
    }
    final normalized = _canonicalLanguage(preference.audioLanguage);
    if (normalized == null) return null;
    for (final item in tracks) {
      final value = _canonicalLanguage(item.language);
      if (value == normalized) return item;
    }
    return null;
  }

  SubtitleTrack? _findSubtitleTrack(
    List<SubtitleTrack> tracks,
    VideoTrackPreference preference,
  ) {
    for (final item in tracks) {
      if (preference.subtitleTrackId != null &&
          item.id == preference.subtitleTrackId) {
        return item;
      }
    }
    final wantedTitle = _normalizeTitle(preference.subtitleTrackTitle);
    if (wantedTitle != null) {
      for (final item in tracks) {
        if (_normalizeTitle(item.title) == wantedTitle) return item;
      }
    }
    final normalized = _canonicalLanguage(preference.subtitleLanguage);
    if (normalized == null) return null;
    for (final item in tracks) {
      final value = _canonicalLanguage(item.language);
      if (value == normalized) return item;
    }
    return null;
  }

  static String? _normalizeTitle(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _canonicalLanguage(String? value) {
    final normalized = value?.trim().toLowerCase().split(RegExp('[-_]')).first;
    if (normalized == null || normalized.isEmpty || normalized == 'und') {
      return null;
    }
    return switch (normalized) {
      'de' || 'deu' || 'ger' || 'deutsch' || 'german' => 'de',
      'en' || 'eng' || 'english' => 'en',
      'ja' || 'jpn' || 'jp' || 'japanese' => 'ja',
      _ => normalized,
    };
  }

  @override
  void dispose() {
    _closed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
  }

  static bool isVideoTrack(LibraryPlaybackTrack track) {
    final path = track.absolutePath.toLowerCase();
    return const {
      '.mp4',
      '.m4v',
      '.mkv',
      '.webm',
      '.mov',
      '.avi',
      '.wmv',
      '.flv',
      '.ts',
      '.m2ts',
    }.any(path.endsWith);
  }
}
