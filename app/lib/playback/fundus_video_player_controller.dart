import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

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
    ]);
  }

  final Player _player;
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
    try {
      _restoringPosition = true;
      await _player.open(
        Playlist([
          for (final item in _tracks) Media(item.absolutePath),
        ], index: _currentIndex),
        play: false,
      );
      _ready = true;
      _loading = false;
      _lastPersistedAt = DateTime.now();
      notifyListeners();
      final resume =
          startPosition ??
          (progress?.position.kind == MediaPositionKind.time &&
                  progress?.fileId == _tracks[_currentIndex].fileId
              ? Duration(
                  milliseconds: ((progress?.position.numericValue ?? 0) * 1000)
                      .round(),
                )
              : Duration.zero);
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
      // media-kit can acknowledge a seek before the first video frame exists
      // without applying it to the decoder. Start decoding first and keep
      // progress persistence suppressed until the saved position is verified.
      await _player.play();
      await _applyTrackPreference(trackPreference);
      if (resume > Duration.zero) {
        _position = await _seekAndVerify(resume);
        notifyListeners();
      }
      _restoringPosition = false;
      _lastPersistedAt = DateTime.now();
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

  Future<void> rememberAudioLanguage(String? language) async {
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
      preference: preference.copyWith(audioLanguage: language),
    );
  }

  Future<void> rememberSubtitlePreference({
    required bool enabled,
    String? language,
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
        subtitleLanguage: language,
      ),
    );
  }

  Future<void> close() async {
    if (_closed) return;
    await persist();
    await _player.pause();
    _ready = false;
  }

  Future<Duration> _seekAndVerify(Duration target) async {
    var actual = _player.state.position;
    for (var attempt = 1; attempt <= 6; attempt++) {
      await _player.seek(target);
      await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      actual = _player.state.position;
      unawaited(
        FundusDiagnostics.instance.record('video.resume_seek_attempt', {
          'work_id': _work?.id,
          'file_id': track?.fileId,
          'attempt': attempt,
          'target_ms': target.inMilliseconds,
          'actual_ms': actual.inMilliseconds,
          'duration_ms': _player.state.duration.inMilliseconds,
        }),
      );
      if ((actual - target).abs() <= const Duration(seconds: 2)) return actual;
    }
    throw StateError(
      'Fortsetzungsposition konnte nach sechs Versuchen nicht gesetzt werden.',
    );
  }

  Future<void> _applyTrackPreference(VideoTrackPreference preference) async {
    // Track metadata is populated asynchronously by media-kit after opening
    // the container. Give it a short window before applying the persisted
    // selection, while leaving the player's automatic choice as fallback.
    for (var attempt = 0; attempt < 8; attempt++) {
      final tracks = _player.state.tracks;
      final audio = _findAudioLanguage(tracks.audio, preference.audioLanguage);
      final subtitles = _findSubtitleLanguage(
        tracks.subtitle,
        preference.subtitleLanguage,
      );
      if (audio != null) await _player.setAudioTrack(audio);
      if (!preference.subtitlesEnabled) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else if (subtitles != null) {
        await _player.setSubtitleTrack(subtitles);
      }
      if (audio != null || subtitles != null || tracks.subtitle.isNotEmpty) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  AudioTrack? _findAudioLanguage(List<AudioTrack> tracks, String? language) {
    if (language == null || language.isEmpty) return null;
    final normalized = language.toLowerCase().split('-').first;
    for (final item in tracks) {
      final value = (item.language ?? '').toLowerCase().split('-').first;
      if (value == normalized) return item;
    }
    return null;
  }

  SubtitleTrack? _findSubtitleLanguage(
    List<SubtitleTrack> tracks,
    String? language,
  ) {
    if (language == null || language.isEmpty) return null;
    final normalized = language.toLowerCase().split('-').first;
    for (final item in tracks) {
      final value = (item.language ?? '').toLowerCase().split('-').first;
      if (value == normalized) return item;
    }
    return null;
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
