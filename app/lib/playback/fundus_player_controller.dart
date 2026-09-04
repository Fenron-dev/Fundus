import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/fundus_diagnostics.dart';
import 'playback_conflict_settings.dart';
import 'playback_autosave_settings.dart';
import 'playback_sleep_timer.dart';
import 'playback_shake_restart.dart';
import 'playback_resume_policy.dart';
import 'fundus_system_media_session.dart';
import 'playlist_session_conflict.dart';
import 'fundus_playback_controller.dart';

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

final class FundusPlayerController extends ChangeNotifier
    implements FundusPlaybackController {
  static const Set<FundusPlaybackCapability> _capabilities = {
    FundusPlaybackCapability.playPause,
    FundusPlaybackCapability.seek,
    FundusPlaybackCapability.previous,
    FundusPlaybackCapability.next,
    FundusPlaybackCapability.speed,
    FundusPlaybackCapability.chapters,
    FundusPlaybackCapability.queue,
    FundusPlaybackCapability.sleepTimer,
    FundusPlaybackCapability.systemMediaControls,
    FundusPlaybackCapability.bookmarks,
  };

  FundusPlayerController({
    this.onConflict,
    this.onPlaylistConflict,
    this.deviceId = 'desktop-local',
    this.deviceName = 'Dieses Gerät',
    this.deviceNameForId,
  }) : _player = Player() {
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
        if (_ready && _playing) _accumulatePlayEvent(value);
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
          if (_autosaveInterval > Duration.zero &&
              elapsed >= _autosaveInterval) {
            unawaited(persist());
          }
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
  final PlaylistSessionConflictResolver? onPlaylistConflict;
  final String deviceId;
  final String deviceName;
  final String Function(String deviceId)? deviceNameForId;
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
  String? _playEventId;
  Duration _playEventLastPosition = Duration.zero;
  int _playEventSeconds = 0;
  bool _playing = false;
  bool _loading = false;
  bool _ready = false;
  bool _persisting = false;
  bool _closed = false;
  bool _skipNextTrackTransition = false;
  double _rate = 1;
  String? _error;
  final Map<String, PlayerWorkProgress> _sessionProgress = {};
  List<LibraryWorkSummary> _queue = [];
  String? _queueLibraryId;
  int _queueIndex = 0;
  RepeatMode _repeatMode = RepeatMode.none;
  List<int> _shuffleOrder = [];
  String? _playlistId;
  String? _playlistName;
  int? _playlistRevision;
  int _playbackSessionRevision = 0;
  List<LibraryPlaylist> _savedPlaylists = [];

  Duration get _autosaveInterval =>
      PlaybackAutosaveSettings.interval(_work?.kind ?? 'audiobook');

  @override
  Set<FundusPlaybackCapability> get capabilities => _capabilities;

  LibraryWorkSummary? get work => _work;
  @override
  String? get playbackWorkId => _work?.id;
  @override
  String? get playbackWorkTitle => _work?.title;
  @override
  String? get playbackKind => _work?.kind;
  @override
  String? get playbackTrackId => track?.fileId;
  @override
  String? get playbackTrackTitle => track?.title;
  LibraryPlaybackTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  @override
  int get currentIndex => _currentIndex;
  @override
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

  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  bool get playing => _playing;
  @override
  bool get loading => _loading;
  double get rate => _rate;
  @override
  String? get error => _error;
  PlaybackSleepTimer get sleepTimer => _sleepTimer;
  List<LibraryWorkSummary> get queue => List.unmodifiable(_queue);
  int get queueIndex => _queueIndex;
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffleEnabled => _shuffleOrder.isNotEmpty;
  String? get playlistId => _playlistId;
  String? get playlistName => _playlistName;
  List<LibraryPlaylist> get savedPlaylists =>
      List.unmodifiable(_savedPlaylists);
  PlayerWorkProgress? progressForWork(String workId) =>
      _sessionProgress[workId];

  void refreshSavedPlaylists() {
    final library = _library;
    if (library == null) return;
    _savedPlaylists = library.listPlaylists();
    notifyListeners();
  }

  Future<void> open(
    FundusLibrary library,
    LibraryWorkSummary work, {
    String? startFileId,
    Duration? startPosition,
    bool preserveQueue = false,
  }) async {
    if (_closed) return;
    if (_ready) {
      await _pauseAndPersist();
      await _finishPlayEvent();
    } else {
      await persist();
    }
    _sleepTimer.cancel();
    _ready = false;
    _loading = true;
    _error = null;
    _library = library;
    final activeWork = await _configureQueue(
      library,
      work,
      preserveQueue: preserveQueue,
    );
    _work = activeWork;
    _tracks = library.playbackTracks(activeWork.id);
    _chapters = await library.playbackChapters(activeWork.id);
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

    final progress = library.loadProgress(activeWork.id);
    _progressRevision = progress?.revision ?? 0;
    unawaited(
      FundusDiagnostics.instance.record('playback.open', {
        'work_id': activeWork.id,
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
      await _startPlayEvent();
      notifyListeners();
      await _player.play();
      if (resumePosition != null && resumePosition > Duration.zero) {
        final appliedPosition = await _seekAndVerify(resumePosition);
        _position = appliedPosition;
        notifyListeners();
        unawaited(
          FundusDiagnostics.instance.record('playback.resume_applied', {
            'work_id': activeWork.id,
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
          'work_id': activeWork.id,
          'error': error.toString(),
        }),
      );
      notifyListeners();
    }
  }

  @override
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
    var latest = library.loadProgress(work.id);
    if (latest == null || latest.revision <= _progressRevision) return;
    final initialLatest = latest;
    var targetIndex = initialLatest.fileId == null
        ? -1
        : _tracks.indexWhere((track) => track.fileId == initialLatest.fileId);
    var incomingPosition = PlaybackResumePolicy.resumePosition(initialLatest);
    final differs =
        targetIndex >= 0 && targetIndex != _currentIndex ||
        (incomingPosition != null &&
            (incomingPosition - _position).abs() > const Duration(seconds: 10));
    if (differs && onConflict != null) {
      var restoredFromHistory = false;
      final choice = await onConflict!(
        PlaybackResumeConflict(
          currentPosition: _position,
          incomingPosition: incomingPosition ?? Duration.zero,
          currentDuration: _effectiveTrackDuration(_currentIndex),
          incomingDuration: _positionDuration(initialLatest.position),
          currentTrack: track?.title ?? 'Aktuelle Datei',
          incomingTrack: targetIndex >= 0
              ? _tracks[targetIndex].title
              : 'Gespeicherte Datei',
          currentChapter: _chapterTitle(_currentIndex, _position),
          incomingChapter: _chapterTitle(
            targetIndex,
            incomingPosition ?? Duration.zero,
          ),
          currentDevice: deviceName,
          incomingDevice: _resolveDeviceName(initialLatest.deviceId),
          incomingSource: 'Server / anderes Gerät',
          loadHistory: () async => library
              .listProgressRevisions(work.id)
              .map(_revisionView)
              .toList(growable: false),
          restoreRevision: (revision) async {
            restoredFromHistory = true;
            latest = library.restoreProgressRevision(
              workId: work.id,
              revision: revision.revision,
              deviceId: deviceId,
              operationId: FundusId.generate(),
            );
          },
        ),
      );
      if (choice == PlaybackConflictChoice.keepCurrent) {
        final currentTrack = track;
        if (currentTrack != null) {
          latest = library.saveProgress(
            workId: work.id,
            fileId: currentTrack.fileId,
            position: _position,
            duration: _effectiveTrackDuration(_currentIndex),
            deviceId: deviceId,
            operationId: FundusId.generate(),
          );
        }
        _progressRevision = latest!.revision;
        return;
      }
      if (!restoredFromHistory && latest!.fileId != null) {
        latest = library.saveProgress(
          workId: work.id,
          fileId: latest!.fileId!,
          position: incomingPosition ?? Duration.zero,
          duration: _positionDuration(latest!.position),
          finished: latest!.finished,
          deviceId: deviceId,
          operationId: FundusId.generate(),
        );
      }
      targetIndex = latest!.fileId == null
          ? -1
          : _tracks.indexWhere((track) => track.fileId == latest!.fileId);
      incomingPosition = PlaybackResumePolicy.resumePosition(latest);
    }
    final selected = latest!;
    if (targetIndex >= 0 && targetIndex != _currentIndex) {
      _skipNextTrackTransition = true;
      await _player.jump(targetIndex);
      _currentIndex = targetIndex;
    }
    final target = incomingPosition;
    if (target != null && target > Duration.zero) {
      _position = await _seekAndVerify(target);
    }
    _progressRevision = selected.revision;
    notifyListeners();
    unawaited(
      FundusDiagnostics.instance.record('playback.progress_refreshed', {
        'work_id': work.id,
        'revision': selected.revision,
        'position_ms': target?.inMilliseconds,
      }),
    );
  }

  PlaybackProgressRevisionView _revisionView(LibraryPlaybackRevision revision) {
    final trackIndex = revision.fileId == null
        ? -1
        : _tracks.indexWhere((track) => track.fileId == revision.fileId);
    final position = Duration(
      milliseconds: ((revision.position.numericValue ?? 0) * 1000).round(),
    );
    return PlaybackProgressRevisionView(
      revision: revision.revision,
      position: position,
      duration: _positionDuration(revision.position),
      track: trackIndex >= 0 ? _tracks[trackIndex].title : 'Gespeicherte Datei',
      chapter: _chapterTitle(trackIndex, position),
      deviceName: _resolveDeviceName(revision.deviceId),
      createdAt: revision.createdAt,
    );
  }

  Duration? _positionDuration(MediaPosition position) {
    final total = position.total;
    return total == null || total <= 0
        ? null
        : Duration(milliseconds: (total * 1000).round());
  }

  Duration? _effectiveTrackDuration(int trackIndex) {
    if (trackIndex == _currentIndex && _duration > Duration.zero) {
      return _duration;
    }
    if (trackIndex < 0 || trackIndex >= _tracks.length) return null;
    return _tracks[trackIndex].duration;
  }

  String? _chapterTitle(int trackIndex, Duration position) {
    if (trackIndex < 0) return null;
    LibraryPlaybackChapter? current;
    for (final chapter in _chapters) {
      if (chapter.trackIndex != trackIndex || chapter.position > position) {
        continue;
      }
      if (current == null || chapter.position >= current.position) {
        current = chapter;
      }
    }
    return current?.title;
  }

  String _resolveDeviceName(String value) {
    if (value == deviceId || value == 'desktop-local') return deviceName;
    return deviceNameForId?.call(value) ?? 'Anderes Gerät';
  }

  /// Returns the user-facing name stored for a synchronized device.
  String displayNameForDevice(String value) => _resolveDeviceName(value);

  @override
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

  @override
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

  @override
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

  void addToQueue(FundusLibrary library, LibraryWorkSummary work) {
    if (_library?.manifest.libraryId != library.manifest.libraryId) {
      _library = library;
      _queue = [work];
      _queueLibraryId = library.manifest.libraryId;
      _savedPlaylists = library.listPlaylists();
      _queueIndex = 0;
      _shuffleOrder = [];
    } else if (!_queue.any((item) => item.id == work.id)) {
      _queue = [..._queue, work];
      if (_shuffleOrder.isNotEmpty) {
        _shuffleOrder = [..._shuffleOrder, _queue.length - 1];
      }
    }
    notifyListeners();
    unawaited(_persistPlaybackSession());
  }

  LibraryPlaylist saveQueueAs(String name, {bool overwrite = false}) {
    final library = _library;
    if (library == null || _queue.isEmpty) {
      throw StateError('Es ist keine Playlist zum Speichern geöffnet.');
    }
    final saved = library.savePlaylist(
      playlistId: overwrite ? _playlistId : null,
      name: name,
      workIds: _queue.map((work) => work.id).toList(growable: false),
      mediaType: _queue.map((work) => work.kind).toSet().length == 1
          ? _queue.first.kind
          : null,
    );
    _playlistId = saved.id;
    _playlistName = saved.name;
    _playlistRevision = saved.revision;
    _savedPlaylists = library.listPlaylists();
    notifyListeners();
    unawaited(_persistPlaybackSession());
    return saved;
  }

  Future<void> loadSavedPlaylist(
    String playlistId, {
    FundusLibrary? library,
  }) async {
    final targetLibrary = library ?? _library;
    final playlist = targetLibrary?.loadPlaylist(playlistId);
    if (targetLibrary == null || playlist == null) return;
    final byId = {for (final work in targetLibrary.listWorks()) work.id: work};
    final works = <LibraryWorkSummary>[];
    for (final workId in playlist.workIds) {
      final work = byId[workId];
      if (work != null) works.add(work);
    }
    if (works.isEmpty) {
      throw StateError('Die Playlist enthält keine verfügbaren Werke.');
    }
    _queue = works;
    _queueLibraryId = targetLibrary.manifest.libraryId;
    _queueIndex = 0;
    _shuffleOrder = [];
    _playlistId = playlist.id;
    _playlistName = playlist.name;
    _playlistRevision = playlist.revision;
    await open(targetLibrary, works.first, preserveQueue: true);
    await _persistPlaybackSession();
  }

  void deleteSavedPlaylist(String playlistId) {
    final library = _library;
    if (library == null) return;
    library.deletePlaylist(playlistId);
    _savedPlaylists = library.listPlaylists();
    if (_playlistId == playlistId) {
      _playlistId = null;
      _playlistName = null;
      _playlistRevision = null;
    }
    notifyListeners();
    unawaited(_persistPlaybackSession());
  }

  Future<void> jumpToQueueWork(int index) async {
    final library = _library;
    if (library == null || index < 0 || index >= _queue.length) return;
    if (index == _queueIndex && _work?.id == _queue[index].id) return;
    _queueIndex = index;
    await open(library, _queue[index], preserveQueue: true);
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length || index == _queueIndex) return;
    final next = [..._queue]..removeAt(index);
    _queue = next;
    if (index < _queueIndex) _queueIndex--;
    _shuffleOrder = [];
    notifyListeners();
    unawaited(_persistPlaybackSession());
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _queue.length ||
        newIndex < 0 ||
        newIndex >= _queue.length ||
        oldIndex == newIndex) {
      return;
    }
    final currentId = _work?.id;
    final next = [..._queue];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    _queue = next;
    _queueIndex = currentId == null
        ? 0
        : _queue
              .indexWhere((work) => work.id == currentId)
              .clamp(0, _queue.length - 1);
    _shuffleOrder = [];
    notifyListeners();
    unawaited(_persistPlaybackSession());
  }

  void setShuffle(bool enabled) {
    if (!enabled || _queue.length < 2) {
      _shuffleOrder = [];
    } else {
      final remaining = List<int>.generate(_queue.length, (index) => index)
        ..remove(_queueIndex)
        ..shuffle(Random());
      _shuffleOrder = [_queueIndex, ...remaining];
    }
    notifyListeners();
    unawaited(_persistPlaybackSession());
  }

  void cycleRepeatMode() {
    _repeatMode = switch (_repeatMode) {
      RepeatMode.none => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.none,
    };
    notifyListeners();
    unawaited(_persistPlaybackSession());
  }

  @override
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
        deviceId: deviceId,
      );
      _progressRevision = saved.revision;
      _sessionProgress[work.id] = PlayerWorkProgress(
        position: _position,
        duration: _duration > Duration.zero ? _duration : currentTrack.duration,
        trackIndex: _currentIndex,
        finished: finished,
      );
      _lastPersistedAt = DateTime.now();
      await _persistPlaybackSession();
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

  @override
  Future<void> close() async {
    if (_closed) return;
    await persist();
    await _finishPlayEvent();
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
    _playEventLastPosition = Duration.zero;
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

  void _accumulatePlayEvent(Duration position) {
    final delta = position - _playEventLastPosition;
    // A seek or a track transition is not time watched. Ignore implausibly
    // large jumps while retaining the new baseline for the next tick.
    if (delta > Duration.zero && delta <= const Duration(seconds: 30)) {
      _playEventSeconds += delta.inSeconds;
    }
    _playEventLastPosition = position;
  }

  Future<void> _startPlayEvent() async {
    final library = _library;
    final work = _work;
    if (library == null || work == null) return;
    try {
      final event = library.startPlayEvent(workId: work.id, deviceId: deviceId);
      _playEventId = event.id;
      _playEventLastPosition = _position;
      _playEventSeconds = 0;
    } catch (error) {
      // History must never prevent playback (for example when a read-only
      // source is opened). Keep the failure observable in diagnostics only.
      unawaited(
        FundusDiagnostics.instance.record('playback.history_start_failed', {
          'work_id': work.id,
          'error': error.toString(),
        }),
      );
    }
  }

  Future<void> _finishPlayEvent() async {
    final eventId = _playEventId;
    final library = _library;
    if (eventId == null || library == null) return;
    _playEventId = null;
    try {
      library.finishPlayEvent(
        eventId: eventId,
        secondsPlayed: _playEventSeconds,
      );
    } catch (error) {
      unawaited(
        FundusDiagnostics.instance.record('playback.history_finish_failed', {
          'event_id': eventId,
          'error': error.toString(),
        }),
      );
    } finally {
      _playEventLastPosition = Duration.zero;
      _playEventSeconds = 0;
    }
  }

  Future<void> _finishLastTrack() async {
    await _sleepTimer.trackEnded();
    final finished = PlaybackResumePolicy.isAtEnd(_position, _duration);
    if (finished || _position > Duration.zero) {
      await persist(finished: finished);
    }
    final nextIndex = _nextQueueIndex();
    final library = _library;
    if (nextIndex != null && library != null) {
      _queueIndex = nextIndex;
      await open(library, _queue[nextIndex], preserveQueue: true);
    }
  }

  Future<LibraryWorkSummary> _configureQueue(
    FundusLibrary library,
    LibraryWorkSummary work, {
    required bool preserveQueue,
  }) async {
    if (preserveQueue && _queue.isNotEmpty) {
      final index = _queue.indexWhere((item) => item.id == work.id);
      if (index >= 0) _queueIndex = index;
      return work;
    }
    final sameLibrary = _queueLibraryId == library.manifest.libraryId;
    if (!sameLibrary || _savedPlaylists.isEmpty) {
      _savedPlaylists = library.listPlaylists();
    }
    if (!sameLibrary || _queue.isEmpty) {
      final restored = library.latestPlaybackSession();
      if (restored != null) {
        _playbackSessionRevision = restored.revision;
        final byId = {for (final item in library.listWorks()) item.id: item};
        final restoredQueue = <LibraryWorkSummary>[];
        for (final item in restored.items) {
          final restoredWork = byId[item.workId];
          if (restoredWork != null) restoredQueue.add(restoredWork);
        }
        final selectedIndex = restoredQueue.indexWhere(
          (item) => item.id == work.id,
        );
        if (restoredQueue.isNotEmpty && selectedIndex >= 0) {
          _queue = restoredQueue;
          _queueLibraryId = library.manifest.libraryId;
          _queueIndex = selectedIndex;
          _repeatMode = restored.repeatMode;
          _shuffleOrder = restored.shuffleOrder.length == restoredQueue.length
              ? [...restored.shuffleOrder]
              : [];
          _playlistId = restored.playlistId;
          _playlistRevision = restored.playlistRevision;
          final savedPlaylist = restored.playlistId == null
              ? null
              : library.loadPlaylist(restored.playlistId!);
          _playlistName = savedPlaylist?.name;
          if (savedPlaylist != null &&
              playlistSessionHasChanged(restored, savedPlaylist) &&
              onPlaylistConflict != null) {
            final choice = await onPlaylistConflict!(
              PlaylistSessionConflict(
                playlistName: savedPlaylist.name,
                sessionRevision: restored.playlistRevision ?? 0,
                currentRevision: savedPlaylist.revision,
                sessionWorkIds: restored.items
                    .map((item) => item.workId)
                    .toList(growable: false),
                currentWorkIds: savedPlaylist.workIds,
              ),
            );
            if (choice == PlaylistSessionChoice.useCurrentPlaylist) {
              final currentQueue = savedPlaylist.workIds
                  .map((workId) => byId[workId])
                  .whereType<LibraryWorkSummary>()
                  .toList(growable: false);
              if (currentQueue.isNotEmpty) {
                final restoredCurrentId = restored.currentItem.workId;
                final currentIndex = currentQueue.indexWhere(
                  (item) => item.id == restoredCurrentId,
                );
                _queue = currentQueue;
                _queueIndex = currentIndex < 0 ? 0 : currentIndex;
                _playlistRevision = savedPlaylist.revision;
                _shuffleOrder = [];
                return _queue[_queueIndex];
              }
            }
          }
          return work;
        }
      }
    }
    _queue = [work];
    _queueLibraryId = library.manifest.libraryId;
    _queueIndex = 0;
    _repeatMode = RepeatMode.none;
    _shuffleOrder = [];
    _playlistId = null;
    _playlistName = null;
    _playlistRevision = null;
    _playbackSessionRevision = library.latestPlaybackSession()?.revision ?? 0;
    return work;
  }

  Future<void> _persistPlaybackSession() async {
    final library = _library;
    final currentTrack = track;
    if (library == null ||
        currentTrack == null ||
        _queue.isEmpty ||
        library.isReadOnly) {
      return;
    }
    final items = <PlaybackSessionItem>[];
    for (var index = 0; index < _queue.length; index++) {
      final work = _queue[index];
      items.add(
        PlaybackSessionItem(
          workId: work.id,
          fileIds: library
              .playbackTracks(work.id)
              .map((track) => track.fileId)
              .toList(growable: false),
          position: index,
        ),
      );
    }
    final sessionDuration = _duration > Duration.zero
        ? _duration
        : currentTrack.duration;
    try {
      final saved = library.savePlaybackSession(
        PlaybackSession(
          id: 'current-${library.manifest.libraryId}',
          playlistId: _playlistId,
          playlistRevision: _playlistRevision,
          items: items,
          currentIndex: _queueIndex.clamp(0, items.length - 1),
          currentPosition: MediaPosition(
            kind: MediaPositionKind.time,
            numericValue: _position.inMilliseconds / 1000,
            total: sessionDuration == null
                ? null
                : sessionDuration.inMilliseconds / 1000,
            fileId: currentTrack.fileId,
          ),
          repeatMode: _repeatMode,
          shuffleOrder: _shuffleOrder,
        ),
        expectedRevision: _playbackSessionRevision,
      );
      _playbackSessionRevision = saved.revision;
    } on PlaybackSessionRevisionConflict catch (conflict) {
      _error =
          'Die Playlist-Sitzung wurde auf einem anderen Gerät geändert '
          '(Revision ${conflict.current.revision}). Öffne sie erneut, um '
          'den aktuellen Stand zu übernehmen.';
      notifyListeners();
    }
  }

  int? _nextQueueIndex() {
    if (_queue.isEmpty) return null;
    if (_repeatMode == RepeatMode.one) return _queueIndex;
    if (_shuffleOrder.isNotEmpty) {
      final position = _shuffleOrder.indexOf(_queueIndex);
      if (position >= 0 && position + 1 < _shuffleOrder.length) {
        return _shuffleOrder[position + 1];
      }
      return _repeatMode == RepeatMode.all ? _shuffleOrder.first : null;
    }
    if (_queueIndex + 1 < _queue.length) return _queueIndex + 1;
    return _repeatMode == RepeatMode.all ? 0 : null;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
