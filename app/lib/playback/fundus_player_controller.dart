import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/fundus_diagnostics.dart';
import 'playback_sleep_timer.dart';
import 'playback_resume_policy.dart';

final class FundusPlayerController extends ChangeNotifier {
  static const progressPersistInterval = Duration(seconds: 5);

  FundusPlayerController() : _player = Player() {
    _sleepTimer = PlaybackSleepTimer(onElapsed: _pauseForSleepTimer);
    _sleepTimer.addListener(notifyListeners);
    _subscriptions.addAll([
      _player.stream.playing.listen((value) {
        _playing = value;
        notifyListeners();
        if (_ready && !value) unawaited(persist());
      }),
      _player.stream.position.listen((value) {
        _position = value;
        notifyListeners();
        if (_ready && _playing && _lastPersistedAt != null) {
          final elapsed = DateTime.now().difference(_lastPersistedAt!);
          if (elapsed >= progressPersistInterval) unawaited(persist());
        }
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
      _player.stream.playlist.listen(_onPlaylist),
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        if (_currentIndex == _tracks.length - 1) {
          unawaited(_finishLastTrack());
        } else {
          unawaited(_sleepTimer.trackEnded());
        }
      }),
      _player.stream.error.listen((value) {
        _error = value;
        notifyListeners();
      }),
    ]);
  }

  final Player _player;
  late final PlaybackSleepTimer _sleepTimer;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  FundusLibrary? _library;
  LibraryWorkSummary? _work;
  List<LibraryPlaybackTrack> _tracks = [];
  int _currentIndex = 0;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime? _lastPersistedAt;
  bool _playing = false;
  bool _loading = false;
  bool _ready = false;
  bool _persisting = false;
  bool _closed = false;
  bool _skipNextTrackTransition = false;
  double _rate = 1;
  String? _error;

  LibraryWorkSummary? get work => _work;
  LibraryPlaybackTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  int get currentIndex => _currentIndex;
  int get trackCount => _tracks.length;
  List<LibraryPlaybackTrack> get tracks => List.unmodifiable(_tracks);
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get loading => _loading;
  double get rate => _rate;
  String? get error => _error;
  PlaybackSleepTimer get sleepTimer => _sleepTimer;

  Future<void> open(
    FundusLibrary library,
    LibraryWorkSummary work, {
    String? startFileId,
    Duration? startPosition,
  }) async {
    if (_closed) return;
    if (_ready) {
      await _pauseAndPersist();
    } else {
      await persist();
    }
    _sleepTimer.cancel();
    _ready = false;
    _loading = true;
    _error = null;
    _library = library;
    _work = work;
    _tracks = library.playbackTracks(work.id);
    _currentIndex = 0;
    _position = Duration.zero;
    notifyListeners();
    if (_tracks.isEmpty) {
      _loading = false;
      _error =
          'Für dieses Werk wurden keine verfügbaren Audiodateien gefunden.';
      notifyListeners();
      return;
    }

    final progress = library.loadProgress(work.id);
    unawaited(
      FundusDiagnostics.instance.record('playback.open', {
        'work_id': work.id,
        'track_count': _tracks.length,
        'stored_file_id': progress?.fileId,
        'stored_position_ms': progress == null
            ? null
            : ((progress.position.numericValue ?? 0) * 1000).round(),
        'stored_finished': progress?.finished,
        'explicit_file_id': startFileId,
        'explicit_position_ms': startPosition?.inMilliseconds,
      }),
    );
    final targetFileId = startFileId ?? progress?.fileId;
    if (targetFileId case final fileId?) {
      final resumeIndex = _tracks.indexWhere((track) => track.fileId == fileId);
      if (resumeIndex >= 0) _currentIndex = resumeIndex;
    }
    try {
      await _player.open(
        Playlist(
          _tracks.map((track) => Media(track.absolutePath)).toList(),
          index: _currentIndex,
        ),
        play: false,
      );
      final resumePosition =
          startPosition ?? PlaybackResumePolicy.resumePosition(progress);
      _ready = true;
      _loading = false;
      _lastPersistedAt = DateTime.now();
      notifyListeners();
      await _player.play();
      if (resumePosition != null && resumePosition > Duration.zero) {
        await _player.seek(resumePosition);
        _position = resumePosition;
        notifyListeners();
        unawaited(
          FundusDiagnostics.instance.record('playback.resume_applied', {
            'work_id': work.id,
            'file_id': track?.fileId,
            'track_index': _currentIndex,
            'position_ms': resumePosition.inMilliseconds,
            'player_position_ms': _player.state.position.inMilliseconds,
          }),
        );
      }
    } catch (error) {
      _loading = false;
      _error = 'Wiedergabe konnte nicht gestartet werden: $error';
      unawaited(
        FundusDiagnostics.instance.record('playback.open_failed', {
          'work_id': work.id,
          'error': error.toString(),
        }),
      );
      notifyListeners();
    }
  }

  Future<void> playOrPause() async {
    if (_player.state.playing) {
      await _pauseAndPersist();
    } else {
      await _player.play();
    }
  }

  Future<void> next() async {
    if (_currentIndex >= _tracks.length - 1) return;
    await persist();
    _skipNextTrackTransition = true;
    await _player.next();
  }

  Future<void> jumpToTrack(int index) async {
    if (!_ready || index < 0 || index >= _tracks.length) return;
    await persist();
    _skipNextTrackTransition = true;
    await _player.jump(index);
    _currentIndex = index;
    _position = Duration.zero;
    notifyListeners();
  }

  Future<void> previous() async {
    if (_position > const Duration(seconds: 5)) {
      await _player.seek(Duration.zero);
      return;
    }
    if (_currentIndex <= 0) return;
    await persist();
    _skipNextTrackTransition = true;
    await _player.previous();
  }

  Future<void> seek(Duration value) => _player.seek(value);

  Future<void> jumpToBookmark(LibraryBookmark bookmark) async {
    if (!_ready || bookmark.workId != _work?.id) {
      throw StateError('Das Lesezeichen gehört nicht zum geöffneten Hörbuch.');
    }
    final fileId = bookmark.fileId;
    final index = fileId == null
        ? _currentIndex
        : _tracks.indexWhere((track) => track.fileId == fileId);
    if (index < 0) {
      throw StateError('Die Datei des Lesezeichens ist nicht mehr verfügbar.');
    }
    if (index != _currentIndex) {
      _skipNextTrackTransition = true;
      await _player.jump(index);
      _currentIndex = index;
    }
    await _player.seek(bookmark.position);
    _position = bookmark.position;
    notifyListeners();
    await persist();
  }

  Future<void> seekRelative(Duration delta) async {
    final target = _position + delta;
    final maximum = _duration;
    await _player.seek(
      target < Duration.zero
          ? Duration.zero
          : maximum > Duration.zero && target > maximum
          ? maximum
          : target,
    );
    await persist();
  }

  Future<void> setRate(double value) async {
    _rate = value;
    notifyListeners();
    await _player.setRate(value);
  }

  Future<void> persist({bool finished = false}) async {
    if (!_ready || _persisting || _closed) return;
    final library = _library;
    final work = _work;
    final currentTrack = track;
    if (library == null || work == null || currentTrack == null) return;
    final playerPosition = _player.state.position;
    if (playerPosition > Duration.zero || _position == Duration.zero) {
      _position = playerPosition;
    }
    _persisting = true;
    try {
      library.saveProgress(
        workId: work.id,
        fileId: currentTrack.fileId,
        position: _position,
        duration: _duration > Duration.zero ? _duration : currentTrack.duration,
        finished: finished,
      );
      _lastPersistedAt = DateTime.now();
      unawaited(
        FundusDiagnostics.instance.record('playback.progress_saved', {
          'work_id': work.id,
          'file_id': currentTrack.fileId,
          'track_index': _currentIndex,
          'position_ms': _position.inMilliseconds,
          'duration_ms': _duration.inMilliseconds,
          'finished': finished,
        }),
      );
    } catch (error) {
      _error = 'Fortschritt konnte nicht gespeichert werden: $error';
      notifyListeners();
      unawaited(
        FundusDiagnostics.instance.record('playback.progress_failed', {
          'work_id': work.id,
          'error': error.toString(),
        }),
      );
    } finally {
      _persisting = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    await persist();
    _closed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _sleepTimer.removeListener(notifyListeners);
    _sleepTimer.dispose();
    await _player.dispose();
  }

  void _onPlaylist(Playlist playlist) {
    if (_tracks.isEmpty || playlist.index == _currentIndex) return;
    if (_skipNextTrackTransition) {
      _skipNextTrackTransition = false;
    } else {
      unawaited(_sleepTimer.trackEnded());
    }
    _currentIndex = playlist.index.clamp(0, _tracks.length - 1);
    _position = Duration.zero;
    notifyListeners();
    if (_ready) unawaited(persist());
  }

  Future<void> _pauseForSleepTimer() async {
    if (_closed) return;
    await _pauseAndPersist();
  }

  Future<void> _pauseAndPersist() async {
    await _player.pause();
    final playerPosition = _player.state.position;
    if (playerPosition > Duration.zero || _position == Duration.zero) {
      _position = playerPosition;
    }
    notifyListeners();
    await persist();
  }

  Future<void> _finishLastTrack() async {
    await _sleepTimer.trackEnded();
    final finished = PlaybackResumePolicy.isAtEnd(_position, _duration);
    if (finished || _position > Duration.zero) {
      await persist(finished: finished);
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
