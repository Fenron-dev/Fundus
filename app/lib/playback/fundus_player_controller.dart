import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/fundus_diagnostics.dart';
import 'playback_conflict_settings.dart';
import 'playback_sleep_timer.dart';
import 'playback_shake_restart.dart';
import 'playback_resume_policy.dart';
import 'fundus_system_media_session.dart';

final class PlayerWorkProgress {
  const PlayerWorkProgress({
    required this.position,
    required this.duration,
    required this.trackIndex,
    required this.finished,
  });

  final Duration position;
  final Duration? duration;
  final int trackIndex;
  final bool finished;
}

final class FundusPlayerController extends ChangeNotifier {
  static const progressPersistInterval = Duration(seconds: 5);

  FundusPlayerController({this.onConflict}) : _player = Player() {
    _sleepTimer = PlaybackSleepTimer(onElapsed: _pauseForSleepTimer);
    _sleepTimer.addListener(notifyListeners);
    _shakeRestart = PlaybackShakeRestartController(
      timer: _sleepTimer,
      resumePlayback: _resumeAfterSleepTimerShake,
    );
    _subscriptions.addAll([
      _player.stream.playing.listen((value) {
        _playing = value;
        _syncSystemMediaSession();
        notifyListeners();
        if (_ready && !value) unawaited(persist());
      }),
      _player.stream.position.listen((value) {
        final previousChapter = _lastChapterIndex;
        _position = value;
        final chapter = currentChapterIndex;
        if (_ready &&
            _playing &&
            previousChapter != null &&
            chapter != null &&
            chapter != previousChapter) {
          unawaited(_sleepTimer.chapterEnded());
        }
        _lastChapterIndex = chapter;
        notifyListeners();
        if (_ready && _playing && _lastPersistedAt != null) {
          final elapsed = DateTime.now().difference(_lastPersistedAt!);
          if (elapsed >= progressPersistInterval) unawaited(persist());
        }
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        _syncSystemMediaSession();
        notifyListeners();
      }),
      _player.stream.playlist.listen(_onPlaylist),
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        unawaited(_sleepTimer.chapterEnded());
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
  final PlaybackConflictResolver? onConflict;
  late final PlaybackSleepTimer _sleepTimer;
  late final PlaybackShakeRestartController _shakeRestart;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  FundusLibrary? _library;
  LibraryWorkSummary? _work;
  List<LibraryPlaybackTrack> _tracks = [];
  List<LibraryPlaybackChapter> _chapters = [];
  int _currentIndex = 0;
  int? _lastChapterIndex;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  DateTime? _lastPersistedAt;
  int _progressRevision = 0;
  bool _playing = false;
  bool _loading = false;
  bool _ready = false;
  bool _persisting = false;
  bool _closed = false;
  bool _skipNextTrackTransition = false;
  double _rate = 1;
  String? _error;
  final Map<String, PlayerWorkProgress> _sessionProgress = {};

  LibraryWorkSummary? get work => _work;
  LibraryPlaybackTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  int get currentIndex => _currentIndex;
  int get trackCount => _tracks.length;
  List<LibraryPlaybackTrack> get tracks => List.unmodifiable(_tracks);
  List<LibraryPlaybackChapter> get chapters => List.unmodifiable(_chapters);
  int? get currentChapterIndex {
    int? result;
    for (var index = 0; index < _chapters.length; index++) {
      final chapter = _chapters[index];
      if (chapter.trackIndex != _currentIndex) continue;
      if (chapter.position <= _position) result = index;
    }
    return result;
  }

  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get loading => _loading;
  double get rate => _rate;
  String? get error => _error;
  PlaybackSleepTimer get sleepTimer => _sleepTimer;
  PlayerWorkProgress? progressForWork(String workId) =>
      _sessionProgress[workId];

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
    _chapters = await library.playbackChapters(work.id);
    _currentIndex = 0;
    _position = Duration.zero;
    _lastChapterIndex = null;
    _activateSystemMediaSession();
    _syncSystemMediaSession();
    notifyListeners();
    if (_tracks.isEmpty) {
      _loading = false;
      _error =
          'Für dieses Werk wurden keine verfügbaren Audiodateien gefunden.';
      notifyListeners();
      return;
    }

    final progress = library.loadProgress(work.id);
    _progressRevision = progress?.revision ?? 0;
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
        final appliedPosition = await _seekAndVerify(resumePosition);
        _position = appliedPosition;
        notifyListeners();
        unawaited(
          FundusDiagnostics.instance.record('playback.resume_applied', {
            'work_id': work.id,
            'file_id': track?.fileId,
            'track_index': _currentIndex,
            'position_ms': resumePosition.inMilliseconds,
            'player_position_ms': appliedPosition.inMilliseconds,
            'verified':
                (appliedPosition - resumePosition).abs() <=
                const Duration(seconds: 2),
          }),
        );
      }
      _syncSystemMediaSession();
      unawaited(_refreshNativeChapters());
    } catch (error) {
      _ready = false;
      await _player.pause();
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
      await _refreshProgressBeforeResume();
      await _player.play();
    }
  }

  Future<void> _refreshProgressBeforeResume() async {
    final library = _library;
    final work = _work;
    if (!_ready || library == null || work == null) return;
    final latest = library.loadProgress(work.id);
    if (latest == null || latest.revision <= _progressRevision) return;
    final targetIndex = latest.fileId == null
        ? -1
        : _tracks.indexWhere((track) => track.fileId == latest.fileId);
    final incomingPosition = PlaybackResumePolicy.resumePosition(latest);
    final differs =
        targetIndex >= 0 && targetIndex != _currentIndex ||
        (incomingPosition != null &&
            (incomingPosition - _position).abs() > const Duration(seconds: 10));
    if (differs && onConflict != null) {
      final choice = await onConflict!(
        PlaybackResumeConflict(
          currentPosition: _position,
          incomingPosition: incomingPosition ?? Duration.zero,
          currentTrack: track?.title ?? 'Aktuelle Datei',
          incomingTrack: targetIndex >= 0
              ? _tracks[targetIndex].title
              : 'Gespeicherte Datei',
          incomingSource: 'Server / anderes Gerät',
        ),
      );
      if (choice == PlaybackConflictChoice.keepCurrent) {
        _progressRevision = latest.revision;
        return;
      }
    }
    if (targetIndex >= 0 && targetIndex != _currentIndex) {
      _skipNextTrackTransition = true;
      await _player.jump(targetIndex);
      _currentIndex = targetIndex;
    }
    final target = incomingPosition;
    if (target != null && target > Duration.zero) {
      _position = await _seekAndVerify(target);
    }
    _progressRevision = latest.revision;
    notifyListeners();
    unawaited(
      FundusDiagnostics.instance.record('playback.progress_refreshed', {
        'work_id': work.id,
        'revision': latest.revision,
        'position_ms': target?.inMilliseconds,
      }),
    );
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

  Future<void> jumpToChapter(LibraryPlaybackChapter chapter) async {
    if (!_ready ||
        chapter.trackIndex < 0 ||
        chapter.trackIndex >= _tracks.length) {
      return;
    }
    await persist();
    if (chapter.trackIndex != _currentIndex) {
      _skipNextTrackTransition = true;
      await _player.jump(chapter.trackIndex);
      _currentIndex = chapter.trackIndex;
    }
    if (chapter.position > Duration.zero) {
      _position = await _seekAndVerify(chapter.position);
    } else {
      await _player.seek(Duration.zero);
      _position = Duration.zero;
    }
    notifyListeners();
    await persist();
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

  Future<void> seek(Duration value) async {
    await _player.seek(value);
    _position = value;
    _syncSystemMediaSession();
    notifyListeners();
  }

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
    _position = _player.state.position;
    _syncSystemMediaSession();
    await persist();
  }

  Future<void> setRate(double value) async {
    _rate = value;
    _syncSystemMediaSession();
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
      final latest = library.loadProgress(work.id);
      if (!_player.state.playing &&
          latest != null &&
          latest.revision > _progressRevision) {
        unawaited(
          FundusDiagnostics.instance.record('playback.stale_write_skipped', {
            'work_id': work.id,
            'local_revision': _progressRevision,
            'current_revision': latest.revision,
          }),
        );
        return;
      }
      final saved = library.saveProgress(
        workId: work.id,
        fileId: currentTrack.fileId,
        position: _position,
        duration: _duration > Duration.zero ? _duration : currentTrack.duration,
        finished: finished,
      );
      _progressRevision = saved.revision;
      _sessionProgress[work.id] = PlayerWorkProgress(
        position: _position,
        duration: _duration > Duration.zero ? _duration : currentTrack.duration,
        trackIndex: _currentIndex,
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
    await _shakeRestart.dispose();
    _sleepTimer.dispose();
    FundusSystemMediaSession.instance.deactivate(this);
    await _player.dispose();
  }

  void _onPlaylist(Playlist playlist) {
    if (_tracks.isEmpty || playlist.index == _currentIndex) return;
    unawaited(_sleepTimer.chapterEnded());
    if (_skipNextTrackTransition) {
      _skipNextTrackTransition = false;
    } else {
      unawaited(_sleepTimer.trackEnded());
    }
    _currentIndex = playlist.index.clamp(0, _tracks.length - 1);
    _position = Duration.zero;
    _lastChapterIndex = null;
    _syncSystemMediaSession();
    notifyListeners();
    if (_ready) unawaited(persist());
  }

  Future<void> _pauseForSleepTimer() async {
    if (_closed) return;
    await _pauseAndPersist();
  }

  Future<void> _resumeAfterSleepTimerShake() async {
    if (_closed || _playing) return;
    await _player.play();
  }

  void _activateSystemMediaSession() {
    FundusSystemMediaSession.instance.activate(
      this,
      FundusSystemMediaControls(
        play: () async {
          if (!_playing) await playOrPause();
        },
        pause: () async {
          if (_playing) await playOrPause();
        },
        seek: seek,
        rewind: () => seekRelative(const Duration(seconds: -10)),
        fastForward: () => seekRelative(const Duration(seconds: 30)),
        previous: previous,
        next: next,
      ),
    );
  }

  void _syncSystemMediaSession() {
    final work = _work;
    final track = this.track;
    if (work == null || track == null) return;
    final coverPath = work.coverPath;
    final authors = work.authors.isNotEmpty
        ? work.authors.join(', ')
        : work.author;
    FundusSystemMediaSession.instance.update(
      owner: this,
      id: '${work.id}:${track.fileId}',
      title: track.title,
      album: work.title,
      artist: authors,
      position: _position,
      duration: _duration > Duration.zero
          ? _duration
          : (track.duration ?? Duration.zero),
      playing: _playing,
      loading: _loading,
      speed: _rate,
      queueIndex: _currentIndex,
      artUri: coverPath == null || coverPath.isEmpty
          ? null
          : Uri.file(coverPath),
    );
  }

  Future<void> _refreshNativeChapters() async {
    final workId = _work?.id;
    final chapters = await _loadNativeChapters();
    if (_closed || chapters.isEmpty || _work?.id != workId) return;
    _chapters = chapters;
    notifyListeners();
  }

  Future<List<LibraryPlaybackChapter>> _loadNativeChapters() async {
    if (_tracks.length != 1 || _player.platform is! NativePlayer) {
      return const [];
    }
    final native = _player.platform! as NativePlayer;
    try {
      int? count;
      for (var attempt = 0; attempt < 6; attempt++) {
        count = int.tryParse(await native.getProperty('chapter-list/count'));
        if (count != null && count > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (count == null || count <= 0 || count > 10000) return const [];
      final entries = <({String title, Duration position})>[];
      for (var index = 0; index < count; index++) {
        final title = (await native.getProperty(
          'chapter-list/$index/title',
        )).trim();
        final seconds = double.tryParse(
          await native.getProperty('chapter-list/$index/time'),
        );
        if (seconds == null || !seconds.isFinite || seconds < 0) continue;
        entries.add((
          title: title.isEmpty ? 'Kapitel ${index + 1}' : title,
          position: Duration(
            microseconds: (seconds * Duration.microsecondsPerSecond).round(),
          ),
        ));
      }
      final totalDuration = _player.state.duration;
      final chapters = [
        for (var index = 0; index < entries.length; index++)
          LibraryPlaybackChapter(
            title: entries[index].title,
            fileId: _tracks.single.fileId,
            trackIndex: 0,
            position: entries[index].position,
            duration: index + 1 < entries.length
                ? entries[index + 1].position - entries[index].position
                : totalDuration > entries[index].position
                ? totalDuration - entries[index].position
                : null,
          ),
      ];
      unawaited(
        FundusDiagnostics.instance.record('playback.chapters_loaded', {
          'work_id': _work?.id,
          'source': 'player',
          'chapter_count': chapters.length,
        }),
      );
      return chapters;
    } catch (error) {
      unawaited(
        FundusDiagnostics.instance.record('playback.chapters_failed', {
          'work_id': _work?.id,
          'error': error.toString(),
        }),
      );
      return const [];
    }
  }

  Future<Duration> _seekAndVerify(Duration target) async {
    var actual = _player.state.position;
    for (var attempt = 1; attempt <= 6; attempt++) {
      await _player.seek(target);
      await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      actual = _player.state.position;
      final difference = (actual - target).abs();
      unawaited(
        FundusDiagnostics.instance.record('playback.resume_seek_attempt', {
          'work_id': _work?.id,
          'attempt': attempt,
          'target_ms': target.inMilliseconds,
          'actual_ms': actual.inMilliseconds,
          'duration_ms': _player.state.duration.inMilliseconds,
        }),
      );
      if (difference <= const Duration(seconds: 2)) return actual;
    }
    throw StateError(
      'Resume-Position konnte nach sechs Versuchen nicht gesetzt werden.',
    );
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
