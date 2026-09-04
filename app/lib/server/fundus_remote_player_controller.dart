import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../diagnostics/fundus_diagnostics.dart';
import '../playback/playback_sleep_timer.dart';
import '../playback/playback_shake_restart.dart';
import '../playback/playback_conflict_settings.dart';
import '../playback/playback_autosave_settings.dart';
import '../playback/playback_resume_policy.dart';
import '../playback/fundus_system_media_session.dart';
import '../playback/video_track_preferences.dart';
import 'fundus_remote_client.dart';
import 'fundus_remote_stream_proxy.dart';
import 'fundus_offline_store.dart';
import '../playback/fundus_playback_controller.dart';
import '../playback/fundus_video_playback_session.dart';

typedef FundusRemoteServerResolver =
    Future<FundusRemoteServer> Function(FundusRemoteServer server);

final class FundusRemoteChapterTarget {
  const FundusRemoteChapterTarget({
    required this.trackIndex,
    required this.position,
  });

  final int trackIndex;
  final Duration position;
}

bool _isVideoWork(FundusRemoteWork work) => VideoWorkKind.isVideo(work.kind);

bool _isVideoTrack(FundusRemoteTrack track) {
  final path = track.title.toLowerCase();
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

FundusRemoteChapterTarget? resolveRemoteChapterTarget(
  List<FundusRemoteTrack> tracks,
  FundusRemoteChapter chapter,
) {
  var trackIndex = chapter.trackIndex;
  if (trackIndex < 0 ||
      trackIndex >= tracks.length ||
      tracks[trackIndex].id != chapter.fileId) {
    trackIndex = tracks.indexWhere((track) => track.id == chapter.fileId);
  }
  if (trackIndex < 0 || chapter.position < Duration.zero) return null;
  return FundusRemoteChapterTarget(
    trackIndex: trackIndex,
    position: chapter.position,
  );
}

final class FundusRemotePlayerController extends ChangeNotifier
    implements FundusPlaybackController {
  static const Set<FundusPlaybackCapability> _capabilities = {
    FundusPlaybackCapability.playPause,
    FundusPlaybackCapability.seek,
    FundusPlaybackCapability.previous,
    FundusPlaybackCapability.next,
    FundusPlaybackCapability.speed,
    FundusPlaybackCapability.trackSelection,
    FundusPlaybackCapability.subtitles,
    FundusPlaybackCapability.screenshots,
    FundusPlaybackCapability.bookmarks,
  };

  FundusRemotePlayerController({
    required this.deviceId,
    required this.deviceName,
    FundusRemoteClient client = const FundusRemoteClient(),
    FundusOfflineStore? offlineStore,
    this.onConflict,
    this.serverResolver,
  }) : _client = client,
       _offlineStore = offlineStore ?? FundusOfflineStore(),
       _player = Player() {
    _videoController = FundusVideoPlaybackSession.createVideoController(
      _player,
    );
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
        final last = _lastPersistedAt;
        if (_ready && _playing && last != null) {
          final interval = PlaybackAutosaveSettings.interval(
            _work?.kind ?? 'audiobook',
          );
          if (interval > Duration.zero &&
              DateTime.now().difference(last) >= interval) {
            unawaited(persist());
          }
        }
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        _syncSystemMediaSession();
        notifyListeners();
      }),
      _player.stream.playlist.listen((playlist) {
        if (_tracks.isEmpty) return;
        if (playlist.index != _currentIndex) {
          unawaited(_sleepTimer.chapterEnded());
        }
        _currentIndex = playlist.index.clamp(0, _tracks.length - 1);
        _position = Duration.zero;
        _lastChapterIndex = null;
        _syncSystemMediaSession();
        notifyListeners();
      }),
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        unawaited(_sleepTimer.chapterEnded());
        if (_currentIndex == _tracks.length - 1) {
          final finished =
              _duration > Duration.zero &&
              _position + const Duration(seconds: 10) >= _duration;
          unawaited(_finishAndAdvanceQueue(finished: finished));
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

  final String deviceId;
  final String deviceName;
  final FundusRemoteClient _client;
  final FundusOfflineStore _offlineStore;
  final PlaybackConflictResolver? onConflict;
  final FundusRemoteServerResolver? serverResolver;
  final Player _player;
  late final VideoController _videoController;
  late final PlaybackSleepTimer _sleepTimer;
  late final PlaybackShakeRestartController _shakeRestart;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  FundusRemoteStreamProxy? _proxy;
  FundusRemoteServer? _server;
  FundusRemoteLibrary? _library;
  FundusRemoteWork? _work;
  List<FundusRemoteTrack> _tracks = const [];
  List<FundusRemoteChapter> _chapters = const [];
  int _currentIndex = 0;
  int? _lastChapterIndex;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _ready = false;
  bool _persisting = false;
  bool _closed = false;
  double _rate = 1;
  DateTime? _lastPersistedAt;
  int _progressRevision = 0;
  String? _error;
  FundusOfflineWork? _offlineWork;
  List<FundusRemoteWork> _workQueue = const [];
  int _workQueueIndex = 0;
  bool _advancingQueue = false;
  String? _playlistId;
  int? _playlistRevision;
  int _sessionRevision = 0;
  RepeatMode _repeatMode = RepeatMode.none;
  List<int> _shuffleOrder = const [];

  FundusRemoteWork? get work => _work;

  @override
  Set<FundusPlaybackCapability> get capabilities => _capabilities;

  @override
  String? get playbackWorkId => _work?.id;

  @override
  String? get playbackWorkTitle => _work?.title;

  @override
  String? get playbackKind => _work?.kind;

  @override
  String? get playbackTrackId => track?.id;

  @override
  String? get playbackTrackTitle => track?.title;

  /// The media-kit player is also used by the shared fullscreen video page.
  Player get player => _player;
  VideoController get videoController => _videoController;
  List<FundusRemoteWork> get workQueue => List.unmodifiable(_workQueue);
  int get workQueueIndex => _workQueueIndex;
  RepeatMode get repeatMode => _repeatMode;
  bool get shuffleEnabled => _shuffleOrder.isNotEmpty;
  FundusRemoteTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  List<FundusRemoteTrack> get tracks => List.unmodifiable(_tracks);
  List<FundusRemoteChapter> get chapters => List.unmodifiable(_chapters);
  String? get offlineCoverPath => _offlineWork?.coverPath;
  @override
  int get currentIndex => _currentIndex;

  @override
  int get trackCount => _tracks.length;
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

  Future<void> open(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    FundusOfflineWork? offlineWork,
    String? startFileId,
    Duration? startPosition,
    bool autoPlay = true,
  }) {
    _workQueue = [work];
    _workQueueIndex = 0;
    _playlistId = null;
    _playlistRevision = null;
    _repeatMode = RepeatMode.none;
    _shuffleOrder = const [];
    return _openWork(
      server,
      library,
      work,
      offlineWork: offlineWork,
      startFileId: startFileId,
      startPosition: startPosition,
      autoPlay: autoPlay,
    );
  }

  Future<void> openQueue(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    List<FundusRemoteWork> works, {
    int startIndex = 0,
    FundusRemotePlaylist? playlist,
  }) async {
    if (works.isEmpty) {
      throw ArgumentError.value(works, 'works', 'Die Playlist ist leer.');
    }
    if (startIndex < 0 || startIndex >= works.length) {
      throw RangeError.index(startIndex, works, 'startIndex');
    }
    await persist();
    PlaybackSession? session;
    try {
      session = await _client.playbackSession(server, library.id);
    } catch (_) {
      session = null;
    }
    _sessionRevision = session?.revision ?? 0;
    _playlistId = playlist?.id;
    _playlistRevision = playlist?.revision;
    _repeatMode = RepeatMode.none;
    _shuffleOrder = const [];
    var queue = List<FundusRemoteWork>.of(works);
    var selectedIndex = startIndex;
    String? startFileId;
    Duration? startPosition;
    if (session != null &&
        playlist != null &&
        session.playlistId == playlist.id &&
        session.playlistRevision == playlist.revision) {
      final byId = {for (final work in works) work.id: work};
      final restored = session.items
          .map((item) => byId[item.workId])
          .whereType<FundusRemoteWork>()
          .toList(growable: false);
      if (restored.length == works.length) {
        queue = restored;
        selectedIndex = session.currentIndex.clamp(0, queue.length - 1);
        _repeatMode = session.repeatMode;
        _shuffleOrder = session.shuffleOrder.length == queue.length
            ? [...session.shuffleOrder]
            : const [];
        startFileId = session.currentPosition.fileId;
        final seconds = session.currentPosition.numericValue;
        startPosition = seconds == null
            ? null
            : Duration(milliseconds: (seconds * 1000).round());
      }
    }
    _workQueue = List.unmodifiable(queue);
    _workQueueIndex = selectedIndex;
    final work = queue[selectedIndex];
    final offlineWork = await _offlineStore.lookup(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    await _openWork(
      server,
      library,
      work,
      offlineWork: offlineWork,
      persistCurrent: false,
      startFileId: startFileId,
      startPosition: startPosition,
    );
  }

  Future<void> _openWork(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    FundusOfflineWork? offlineWork,
    bool persistCurrent = true,
    String? startFileId,
    Duration? startPosition,
    bool autoPlay = true,
  }) async {
    if (_closed) return;
    final openStarted = Stopwatch()..start();
    var sourceReadyMs = 0;
    var progressReadyMs = 0;
    var playerReadyMs = 0;
    if (persistCurrent) await persist();
    await _player.pause();
    _sleepTimer.cancel();
    await _proxy?.close();
    _proxy = null;
    _ready = false;
    _loading = true;
    _error = null;
    _server = server;
    _library = library;
    _work = work;
    _offlineWork = offlineWork;
    _tracks = const [];
    _chapters = const [];
    _currentIndex = 0;
    _lastChapterIndex = null;
    _position = Duration.zero;
    _activateSystemMediaSession();
    notifyListeners();
    try {
      List<FundusRemoteTrack> tracks;
      final List<FundusRemoteChapter> chapters;
      if (offlineWork == null) {
        final detail = await _withReconnect(
          (active) => _client.work(active, library.id, work),
        );
        tracks = detail.tracks;
        chapters = detail.chapters;
      } else {
        tracks = [
          for (final track in offlineWork.tracks)
            FundusRemoteTrack(
              id: track.id,
              title: track.title,
              position: track.position,
              size: track.size,
              duration: track.duration,
              audioMetadata: track.audioMetadata,
            ),
        ];
        chapters = offlineWork.chapters;
      }
      if (_isVideoWork(work)) {
        // Document works can contain a poster/cover alongside the actual
        // media. Never put those image files into the video playlist.
        tracks = tracks.where(_isVideoTrack).toList(growable: false);
      }
      sourceReadyMs = openStarted.elapsedMilliseconds;
      FundusRemoteProgress? localProgress;
      if (offlineWork != null) {
        localProgress = await _offlineStore.loadProgress(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
        );
      }
      FundusRemoteProgress? serverProgress;
      if (offlineWork == null) {
        try {
          serverProgress = await _withReconnect(
            (active) => _client.progress(active, library.id, work.id),
          );
        } catch (_) {
          serverProgress = null;
        }
      }
      progressReadyMs = openStarted.elapsedMilliseconds;
      if (tracks.isEmpty) {
        throw StateError('Dieses Werk enthält keine abspielbaren Dateien.');
      }
      _tracks = tracks;
      _chapters = [
        for (final chapter in chapters)
          if (resolveRemoteChapterTarget(tracks, chapter) != null) chapter,
      ];
      _syncSystemMediaSession();
      var progress = serverProgress ?? localProgress;
      if (localProgress != null &&
          localProgress.pendingSync &&
          serverProgress != null) {
        final localIndex = localProgress.fileId == null
            ? -1
            : tracks.indexWhere((track) => track.id == localProgress!.fileId);
        final serverIndex = serverProgress.fileId == null
            ? -1
            : tracks.indexWhere((track) => track.id == serverProgress!.fileId);
        final differs =
            localIndex != serverIndex ||
            (localProgress.position - serverProgress.position).abs() >
                const Duration(seconds: 10);
        if (differs && onConflict != null) {
          var restoredFromHistory = false;
          final choice = await onConflict!(
            PlaybackResumeConflict(
              currentPosition: localProgress.position,
              incomingPosition: serverProgress.position,
              currentDuration: localProgress.duration,
              incomingDuration: serverProgress.duration,
              currentTrack: localIndex >= 0
                  ? tracks[localIndex].title
                  : 'Lokale Datei',
              incomingTrack: serverIndex >= 0
                  ? tracks[serverIndex].title
                  : 'Gespeicherte Datei',
              currentChapter: _chapterTitle(localIndex, localProgress.position),
              incomingChapter: _chapterTitle(
                serverIndex,
                serverProgress.position,
              ),
              currentDevice: deviceName,
              incomingDevice: serverProgress.deviceName ?? server.name,
              incomingSource: server.name,
              loadHistory: () async {
                final revisions = await _withReconnect(
                  (active) =>
                      _client.progressRevisions(active, library.id, work.id),
                );
                return revisions.map(_revisionView).toList(growable: false);
              },
              restoreRevision: (revision) async {
                restoredFromHistory = true;
                final operationId = _operationId();
                serverProgress = await _withReconnect(
                  (active) => _client.restoreProgressRevision(
                    active,
                    libraryId: library.id,
                    workId: work.id,
                    revision: revision.revision,
                    deviceId: deviceId,
                    operationId: operationId,
                  ),
                );
              },
            ),
          );
          if (choice == PlaybackConflictChoice.keepCurrent) {
            serverProgress =
                await _saveProgressChoice(
                  library: library,
                  work: work,
                  fileId: localProgress.fileId,
                  position: localProgress.position,
                  duration: localProgress.duration,
                  finished: localProgress.finished,
                ) ??
                serverProgress;
            progress = serverProgress ?? localProgress;
          } else {
            if (!restoredFromHistory) {
              serverProgress =
                  await _saveProgressChoice(
                    library: library,
                    work: work,
                    fileId: serverProgress?.fileId,
                    position: serverProgress?.position ?? Duration.zero,
                    duration: serverProgress?.duration,
                    finished: serverProgress?.finished ?? false,
                  ) ??
                  serverProgress;
            }
            progress = serverProgress;
          }
        }
      }
      if (offlineWork != null &&
          serverProgress != null &&
          identical(progress, serverProgress)) {
        await _offlineStore.cacheProgress(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
          progress: serverProgress!,
          replacePending: true,
        );
      }
      _progressRevision = max(
        localProgress?.revision ?? 0,
        serverProgress?.revision ?? 0,
      );
      final resumeIndex = progress?.fileId == null
          ? -1
          : _tracks.indexWhere((item) => item.id == progress!.fileId);
      final explicitIndex = startFileId == null
          ? -1
          : _tracks.indexWhere((item) => item.id == startFileId);
      if (explicitIndex >= 0) {
        _currentIndex = explicitIndex;
      } else if (resumeIndex >= 0) {
        _currentIndex = resumeIndex;
      }
      final resumePosition =
          startPosition ??
          PlaybackResumePolicy.resumeTime(
            position: progress?.position,
            total: progress?.duration,
            finished: progress?.finished ?? false,
          );
      final useNativeVideoResume =
          _isVideoWork(work) &&
          resumePosition != null &&
          !(progress?.finished ?? false) &&
          resumePosition > Duration.zero;
      final List<Media> media;
      if (offlineWork == null) {
        final proxy = await FundusRemoteStreamProxy.start(
          server: _server ?? server,
          libraryId: library.id,
          workId: work.id,
          tracks: _tracks,
          client: _client,
        );
        _proxy = proxy;
        media = [
          for (var index = 0; index < proxy.urls.length; index++)
            Media(proxy.urls[index].toString()),
        ];
      } else {
        // Keep the native playlist aligned with `_tracks`. Offline works may
        // contain a cover or other sidecar files before the playable videos;
        // using the raw offline order here shifts every resume index by one
        // and can attach audio to the wrong (or non-video) file.
        final pathsById = {
          for (final item in offlineWork.tracks) item.id: item.path,
        };
        media = [
          for (final item in _tracks)
            if (pathsById[item.id] case final path?) Media(path),
        ];
        if (media.length != _tracks.length) {
          throw StateError('Offline-Playlist enthält nicht alle Videodateien.');
        }
      }
      await _player.open(Playlist(media, index: _currentIndex), play: false);
      playerReadyMs = openStarted.elapsedMilliseconds;
      _ready = true;
      _loading = false;
      _lastPersistedAt = DateTime.now();
      notifyListeners();
      if (_isVideoWork(work)) {
        final profile = await _loadVideoTrackProfile(
          server: server,
          library: library,
          work: work,
        );
        final preference = VideoTrackPreferences.overlayPortableProfile(
          await VideoTrackPreferences.load(
            kind: work.kind,
            workId: work.id,
            fileId: track?.id,
            season: track?.episode?.season,
          ),
          profile,
          fileId: track?.id,
          season: track?.episode?.season,
        );
        await _applyVideoTrackPreference(preference);
      }
      if (useNativeVideoResume) {
        // Apply the resume after stream selection while the player is still
        // paused. Supplying Media.start can advance audio without priming the
        // video texture, especially for an already visited MKV/MP4. An
        // explicit verified seek keeps remote and offline playback aligned.
        await FundusVideoPlaybackSession.waitForVideoParameters(_player);
        _position = await FundusVideoPlaybackSession.seekAndVerify(
          _player,
          resumePosition,
        );
        notifyListeners();
      }
      if (autoPlay) await _player.play();
      if (resumePosition != null &&
          !useNativeVideoResume &&
          !(progress?.finished ?? false) &&
          resumePosition > Duration.zero) {
        _position = await FundusVideoPlaybackSession.seekAndVerify(
          _player,
          resumePosition,
        );
        notifyListeners();
      }
      if (resumePosition != null &&
          !(progress?.finished ?? false) &&
          resumePosition > Duration.zero) {
        unawaited(
          _recordRemoteResume(
            workId: work.id,
            target: resumePosition,
            offline: offlineWork != null,
            nativeStart: useNativeVideoResume,
          ),
        );
      }
      _syncSystemMediaSession();
      if (offlineWork != null) {
        // Local playback is ready immediately. A reachable server may still
        // contribute a newer position, but reconnect attempts must never hold
        // up playback when the device is offline.
        unawaited(_refreshProgressBeforeResume());
      }
      unawaited(
        FundusDiagnostics.instance.record('remote.playback_opened', {
          'work_id': work.id,
          'offline': offlineWork != null,
          'track_count': tracks.length,
          'source_ready_ms': sourceReadyMs,
          'progress_ready_ms': progressReadyMs,
          'player_ready_ms': playerReadyMs,
          'total_ms': openStarted.elapsedMilliseconds,
        }),
      );
    } catch (error) {
      _loading = false;
      _ready = false;
      _error = 'Remote-Wiedergabe konnte nicht gestartet werden: $error';
      notifyListeners();
      unawaited(
        FundusDiagnostics.instance.record('remote.playback_open_failed', {
          'work_id': work.id,
          'offline': offlineWork != null,
          'track_count': offlineWork?.tracks.length ?? 0,
          'source_ready_ms': sourceReadyMs,
          'progress_ready_ms': progressReadyMs,
          'player_ready_ms': playerReadyMs,
          'total_ms': openStarted.elapsedMilliseconds,
          'error': error.runtimeType.toString(),
        }),
      );
    }
  }

  @override
  Future<void> playOrPause() async {
    if (!_ready) return;
    if (_playing) {
      await _player.pause();
      await persist();
    } else {
      await _refreshProgressBeforeResume();
      await _player.play();
    }
  }

  Future<void> _refreshProgressBeforeResume() async {
    final library = _library;
    final work = _work;
    if (!_ready || _server == null || library == null || work == null) return;
    FundusRemoteProgress? latest;
    try {
      latest = await _withReconnect(
        (active) => _client.progress(active, library.id, work.id),
      );
    } catch (_) {
      return;
    }
    if (_work?.id != work.id || _library?.id != library.id) return;
    if (latest == null || latest.revision <= _progressRevision) return;
    final initialLatest = latest;
    var targetIndex = initialLatest.fileId == null
        ? -1
        : _tracks.indexWhere((track) => track.id == initialLatest.fileId);
    final differs =
        targetIndex >= 0 && targetIndex != _currentIndex ||
        (initialLatest.position - _position).abs() >
            const Duration(seconds: 10);
    if (differs && onConflict != null) {
      var restoredFromHistory = false;
      final choice = await onConflict!(
        PlaybackResumeConflict(
          currentPosition: _position,
          incomingPosition: initialLatest.position,
          currentDuration: _effectiveTrackDuration(_currentIndex),
          incomingDuration: initialLatest.duration,
          currentTrack: track?.title ?? 'Aktuelle Datei',
          incomingTrack: targetIndex >= 0
              ? _tracks[targetIndex].title
              : 'Gespeicherte Datei',
          currentChapter: _chapterTitle(_currentIndex, _position),
          incomingChapter: _chapterTitle(targetIndex, initialLatest.position),
          currentDevice: deviceName,
          incomingDevice: initialLatest.deviceName ?? _server!.name,
          incomingSource: _server!.name,
          loadHistory: () async {
            final revisions = await _withReconnect(
              (active) =>
                  _client.progressRevisions(active, library.id, work.id),
            );
            return revisions.map(_revisionView).toList(growable: false);
          },
          restoreRevision: (revision) async {
            restoredFromHistory = true;
            latest = await _withReconnect(
              (active) => _client.restoreProgressRevision(
                active,
                libraryId: library.id,
                workId: work.id,
                revision: revision.revision,
                deviceId: deviceId,
                operationId: _operationId(),
              ),
            );
          },
        ),
      );
      if (choice == PlaybackConflictChoice.keepCurrent) {
        latest =
            await _saveProgressChoice(
              library: library,
              work: work,
              fileId: track?.id,
              position: _position,
              duration: _effectiveTrackDuration(_currentIndex),
              finished: false,
            ) ??
            latest;
        _progressRevision = latest?.revision ?? initialLatest.revision;
        return;
      }
      if (!restoredFromHistory) {
        latest =
            await _saveProgressChoice(
              library: library,
              work: work,
              fileId: latest!.fileId,
              position: latest!.position,
              duration: latest!.duration,
              finished: latest!.finished,
            ) ??
            latest;
      }
      targetIndex = latest!.fileId == null
          ? -1
          : _tracks.indexWhere((track) => track.id == latest!.fileId);
    }
    final selected = latest!;
    if (targetIndex >= 0 && targetIndex != _currentIndex) {
      await _player.jump(targetIndex);
      _currentIndex = targetIndex;
    }
    if (!selected.finished && selected.position > Duration.zero) {
      _position = await FundusVideoPlaybackSession.seekAndVerify(
        _player,
        selected.position,
      );
    }
    _progressRevision = selected.revision;
    notifyListeners();
  }

  PlaybackProgressRevisionView _revisionView(
    FundusRemoteProgressRevision revision,
  ) {
    final trackIndex = revision.fileId == null
        ? -1
        : _tracks.indexWhere((track) => track.id == revision.fileId);
    return PlaybackProgressRevisionView(
      revision: revision.revision,
      position: revision.position,
      duration: revision.duration,
      track: trackIndex >= 0 ? _tracks[trackIndex].title : 'Gespeicherte Datei',
      chapter: _chapterTitle(trackIndex, revision.position),
      deviceName: revision.deviceName,
      createdAt: revision.createdAt,
    );
  }

  Future<FundusRemoteProgress?> _saveProgressChoice({
    required FundusRemoteLibrary library,
    required FundusRemoteWork work,
    required String? fileId,
    required Duration position,
    required Duration? duration,
    required bool finished,
  }) async {
    if (fileId == null) return null;
    final operationId = _operationId();
    return _withReconnect(
      (active) => _client.saveProgress(
        active,
        libraryId: library.id,
        workId: work.id,
        fileId: fileId,
        position: position,
        duration: duration,
        finished: finished,
        deviceId: deviceId,
        operationId: operationId,
      ),
    );
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
    FundusRemoteChapter? current;
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

  @override
  Future<void> seek(Duration value) async {
    await _player.seek(value);
    _position = value;
    _syncSystemMediaSession();
    notifyListeners();
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

  @override
  Future<void> next() async {
    if (!_ready) return;
    if (_currentIndex < _tracks.length - 1) {
      await persist();
      await _player.next();
      return;
    }
    await _advanceWorkQueue();
  }

  @override
  Future<void> previous() async {
    if (!_ready) return;
    if (_position > const Duration(seconds: 5)) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      await persist();
      await _player.previous();
    } else if (_workQueueIndex > 0) {
      await persist();
      _ready = false;
      _workQueueIndex--;
      await _openQueuedWork(persistCurrent: false);
    }
  }

  Future<void> _finishAndAdvanceQueue({required bool finished}) async {
    if (_advancingQueue) return;
    _advancingQueue = true;
    try {
      await persist(finished: finished);
      final nextIndex = _nextWorkQueueIndex();
      if (nextIndex != null) {
        _ready = false;
        _workQueueIndex = nextIndex;
        await _openQueuedWork(persistCurrent: false);
      }
    } finally {
      _advancingQueue = false;
    }
  }

  Future<void> _advanceWorkQueue() async {
    if (_workQueueIndex >= _workQueue.length - 1 || _advancingQueue) return;
    _advancingQueue = true;
    try {
      await persist();
      _ready = false;
      _workQueueIndex++;
      await _openQueuedWork(persistCurrent: false);
    } finally {
      _advancingQueue = false;
    }
  }

  Future<void> _openQueuedWork({required bool persistCurrent}) async {
    final server = _server;
    final library = _library;
    if (server == null || library == null || _workQueue.isEmpty) return;
    final work = _workQueue[_workQueueIndex];
    final offlineWork = await _offlineStore.lookup(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    await _openWork(
      server,
      library,
      work,
      offlineWork: offlineWork,
      persistCurrent: persistCurrent,
    );
  }

  int? _nextWorkQueueIndex() {
    if (_workQueue.isEmpty) return null;
    if (_repeatMode == RepeatMode.one) return _workQueueIndex;
    if (_shuffleOrder.isNotEmpty) {
      final position = _shuffleOrder.indexOf(_workQueueIndex);
      if (position >= 0 && position + 1 < _shuffleOrder.length) {
        return _shuffleOrder[position + 1];
      }
      return _repeatMode == RepeatMode.all ? _shuffleOrder.first : null;
    }
    if (_workQueueIndex + 1 < _workQueue.length) return _workQueueIndex + 1;
    return _repeatMode == RepeatMode.all ? 0 : null;
  }

  Future<void> _persistPlaybackSession() async {
    final library = _library;
    final currentTrack = track;
    if (library == null ||
        currentTrack == null ||
        _workQueue.isEmpty ||
        _playlistId == null) {
      return;
    }
    final session = PlaybackSession(
      id: 'current-${library.id}',
      playlistId: _playlistId,
      playlistRevision: _playlistRevision,
      items: [
        for (var index = 0; index < _workQueue.length; index++)
          PlaybackSessionItem(
            workId: _workQueue[index].id,
            fileIds: index == _workQueueIndex
                ? _tracks.map((track) => track.id).toList(growable: false)
                : const [],
            position: index,
          ),
      ],
      currentIndex: _workQueueIndex,
      currentPosition: MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: _position.inMilliseconds / 1000,
        total: _duration > Duration.zero
            ? _duration.inMilliseconds / 1000
            : null,
        fileId: currentTrack.id,
      ),
      repeatMode: _repeatMode,
      shuffleOrder: _shuffleOrder,
    );
    try {
      final saved = await _withReconnect(
        (active) => _client.savePlaybackSession(
          active,
          libraryId: library.id,
          session: session,
          deviceId: deviceId,
          expectedRevision: _sessionRevision,
        ),
      );
      _sessionRevision = saved.revision;
    } on FundusRemotePlaybackSessionConflict catch (error) {
      _error =
          'Die Playlist-Sitzung wurde auf einem anderen Gerät geändert. '
          'Öffne die Playlist erneut, um Revision '
          '${error.current?.revision ?? '?'} zu übernehmen.';
      notifyListeners();
    } catch (_) {
      // Einzelner Werkfortschritt bleibt auch ohne Queue-Snapshot nutzbar.
    }
  }

  Future<void> jumpToTrack(int index) async {
    if (!_ready || index < 0 || index >= _tracks.length) return;
    await persist();
    await _player.jump(index);
  }

  Future<void> jumpToChapter(FundusRemoteChapter chapter) async {
    if (!_ready) return;
    final target = resolveRemoteChapterTarget(_tracks, chapter);
    if (target == null) {
      throw StateError('Das Kapitel gehört nicht zum geöffneten Hörbuch.');
    }
    await persist();
    if (target.trackIndex != _currentIndex) {
      await _player.jump(target.trackIndex);
      _currentIndex = target.trackIndex;
    }
    await _player.seek(target.position);
    _position = target.position;
    _lastChapterIndex = _chapters.indexOf(chapter);
    notifyListeners();
    await persist();
  }

  @override
  Future<void> persist({bool finished = false}) async {
    if (!_ready || _persisting || _closed) return;
    final server = _server;
    final library = _library;
    final work = _work;
    final currentTrack = track;
    if (server == null ||
        library == null ||
        work == null ||
        currentTrack == null) {
      return;
    }
    final actual = _player.state.position;
    if (actual > Duration.zero || _position == Duration.zero) {
      _position = actual;
    }
    _persisting = true;
    try {
      final measuredDuration = _duration > Duration.zero
          ? _duration
          : currentTrack.duration;
      final effectiveDuration =
          measuredDuration != null && measuredDuration < _position
          ? _position
          : measuredDuration;
      if (!_playing) {
        try {
          final latest = await _withReconnect(
            (active) => _client.progress(active, library.id, work.id),
          );
          if (latest != null && latest.revision > _progressRevision) return;
        } catch (_) {
          // Offline-Wiedergabe bleibt über die lokale Queue speicherbar.
        }
      }
      FundusOfflinePendingProgress? offlinePending;
      if (_offlineWork != null) {
        offlinePending = await _offlineStore.saveProgress(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
          fileId: currentTrack.id,
          position: _position,
          finished: finished,
        );
      }
      try {
        final operationId = _operationId();
        final saved = await _withReconnect(
          (active) => _client.saveProgress(
            active,
            libraryId: library.id,
            workId: work.id,
            fileId: currentTrack.id,
            position: _position,
            duration: effectiveDuration,
            finished: finished,
            deviceId: deviceId,
            operationId: operationId,
          ),
        );
        _progressRevision = saved.revision;
        if (offlinePending != null) {
          await _offlineStore.markProgressSynced(offlinePending);
        }
      } catch (_) {
        if (_offlineWork == null) rethrow;
      }
      _lastPersistedAt = DateTime.now();
      await _persistPlaybackSession();
    } catch (_) {
      _error = 'Fortschritt konnte nicht zum Server übertragen werden.';
      notifyListeners();
    } finally {
      _persisting = false;
    }
  }

  @override
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
    await _proxy?.close();
    _proxy = null;
  }

  Future<T> _withReconnect<T>(
    Future<T> Function(FundusRemoteServer server) operation,
  ) async {
    final server = _server;
    if (server == null) throw StateError('Kein Server ausgewählt.');
    try {
      return await operation(server);
    } catch (firstError) {
      final resolver = serverResolver;
      if (resolver == null) rethrow;
      unawaited(
        FundusDiagnostics.instance.record('remote.player_reconnect_started', {
          'server_id': server.id,
          'reason': firstError.runtimeType.toString(),
        }),
      );
      try {
        final relocated = await resolver(server);
        _server = relocated;
        final result = await operation(relocated);
        unawaited(
          FundusDiagnostics.instance
              .record('remote.player_reconnect_completed', {
                'server_id': server.id,
                'endpoint_changed': relocated.baseUri != server.baseUri,
              }),
        );
        return result;
      } catch (retryError) {
        unawaited(
          FundusDiagnostics.instance.record('remote.player_reconnect_failed', {
            'server_id': server.id,
            'reason': retryError.runtimeType.toString(),
          }),
        );
        rethrow;
      }
    }
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
    final coverPath = _offlineWork?.coverPath;
    FundusSystemMediaSession.instance.update(
      owner: this,
      id: '${work.id}:${track.id}',
      title: track.title,
      album: work.title,
      artist: work.authors.join(', '),
      position: _position,
      duration: _duration > Duration.zero
          ? _duration
          : (track.duration ?? Duration.zero),
      playing: _playing,
      loading: _loading,
      speed: _rate,
      queueIndex: _currentIndex,
      artUri: coverPath != null && coverPath.isNotEmpty
          ? Uri.file(coverPath)
          : _proxy?.coverUrl,
    );
  }

  String _operationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return 'remote-${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  Future<void> _recordRemoteResume({
    required String workId,
    required Duration target,
    required bool offline,
    required bool nativeStart,
  }) async {
    if (nativeStart) {
      await Future<void>.delayed(const Duration(milliseconds: 750));
    }
    if (_closed || _work?.id != workId) return;
    await FundusDiagnostics.instance.record('remote.resume_applied', {
      'work_id': workId,
      'file_id': track?.id,
      'position_ms': target.inMilliseconds,
      'player_position_ms': _player.state.position.inMilliseconds,
      'offline': offline,
      'native_start': nativeStart,
      'buffering': _player.state.buffering,
    });
  }

  Future<void> rememberVideoAudioTrack(AudioTrack selected) async {
    final work = _work;
    final current = track;
    final server = _server;
    final library = _library;
    if (work == null || current == null || server == null || library == null)
      return;
    final profile = await _loadVideoTrackProfile(
      server: server,
      library: library,
      work: work,
    );
    final preference = VideoTrackPreferences.overlayPortableProfile(
      await VideoTrackPreferences.load(
        kind: work.kind,
        workId: work.id,
        fileId: current.id,
        season: current.episode?.season,
      ),
      profile,
      fileId: current.id,
      season: current.episode?.season,
    );
    final updated = preference.copyWith(
      audioLanguage: selected.language,
      audioTrackId: selected.id,
      audioTrackTitle: selected.title,
    );
    await VideoTrackPreferences.save(
      kind: work.kind,
      workId: work.id,
      fileId: current.id,
      season: current.episode?.season,
      preference: updated,
    );
    await _saveVideoTrackProfile(
      server: server,
      library: library,
      work: work,
      existing: profile,
      preference: updated,
      fileId: current.id,
      season: current.episode?.season,
    );
  }

  Future<void> rememberVideoSubtitleTrack(
    bool enabled,
    SubtitleTrack? selected,
  ) async {
    final work = _work;
    final current = track;
    final server = _server;
    final library = _library;
    if (work == null || current == null || server == null || library == null)
      return;
    final profile = await _loadVideoTrackProfile(
      server: server,
      library: library,
      work: work,
    );
    final preference = VideoTrackPreferences.overlayPortableProfile(
      await VideoTrackPreferences.load(
        kind: work.kind,
        workId: work.id,
        fileId: current.id,
        season: current.episode?.season,
      ),
      profile,
      fileId: current.id,
      season: current.episode?.season,
    );
    final updated = preference.copyWith(
      subtitlesEnabled: enabled,
      subtitleLanguage: selected?.language,
      subtitleTrackId: selected?.id,
      subtitleTrackTitle: selected?.title,
    );
    await VideoTrackPreferences.save(
      kind: work.kind,
      workId: work.id,
      fileId: current.id,
      season: current.episode?.season,
      preference: updated,
    );
    await _saveVideoTrackProfile(
      server: server,
      library: library,
      work: work,
      existing: profile,
      preference: updated,
      fileId: current.id,
      season: current.episode?.season,
    );
  }

  /// Stores a timestamp bookmark for screenshots and the shared video
  /// player. Remote and offline playback use the same annotation contract so
  /// a bookmark created on one device is available after reconnecting.
  Future<void> addBookmarkAtCurrent({String? label, String? note}) async {
    final server = _server;
    final library = _library;
    final work = _work;
    final current = track;
    if (server == null || library == null || work == null || current == null) {
      return;
    }
    final position = MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: _position.inMilliseconds / 1000,
      total: _duration > Duration.zero
          ? _duration.inMilliseconds / 1000
          : current.duration?.inMilliseconds == null
          ? null
          : current.duration!.inMilliseconds / 1000,
      fileId: current.id,
      label: current.title,
    );
    if (_offlineWork != null) {
      final annotations = await _offlineStore.loadAnnotations(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
      );
      await _offlineStore.cacheAnnotations(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        annotations: WorkAnnotations(
          tags: annotations.tags,
          notes: annotations.notes,
          bookmarks: [
            ...annotations.bookmarks,
            LibraryBookmark(
              id: FundusId.generate(),
              workId: work.id,
              fileId: current.id,
              mediaPosition: position,
              label: label,
              note: note,
              createdAt: DateTime.now(),
            ),
          ],
          highlights: annotations.highlights,
        ),
      );
      return;
    }
    final result = await _withReconnect(
      (active) => _client.saveBookmark(
        active,
        libraryId: library.id,
        workId: work.id,
        fileId: current.id,
        position: position,
        label: label,
        note: note,
      ),
    );
    await _offlineStore.cacheAnnotations(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
      annotations: result,
    );
  }

  Future<Map<String, Object?>?> _loadVideoTrackProfile({
    required FundusRemoteServer server,
    required FundusRemoteLibrary library,
    required FundusRemoteWork work,
  }) async {
    final profileDeviceKey = _videoProfileDeviceKey;
    if (_offlineWork != null) {
      return _offlineStore.loadReaderProfile(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
        deviceKey: profileDeviceKey,
        readerKind: 'video-tracks',
      );
    }
    try {
      return await _withReconnect(
        (active) => _client.readerProfile(
          active,
          libraryId: library.id,
          workId: work.id,
          deviceKey: profileDeviceKey,
          readerKind: 'video-tracks',
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveVideoTrackProfile({
    required FundusRemoteServer server,
    required FundusRemoteLibrary library,
    required FundusRemoteWork work,
    required Map<String, Object?>? existing,
    required VideoTrackPreference preference,
    String? fileId,
    int? season,
  }) async {
    final profileDeviceKey = _videoProfileDeviceKey;
    final profile = VideoTrackPreferences.updatePortableProfile(
      existing,
      preference,
      fileId: fileId,
      season: season,
    );
    try {
      if (_offlineWork != null) {
        await _offlineStore.saveReaderProfile(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
          deviceKey: profileDeviceKey,
          readerKind: 'video-tracks',
          profile: profile,
        );
      } else {
        await _withReconnect(
          (active) => _client.saveReaderProfile(
            active,
            libraryId: library.id,
            workId: work.id,
            deviceKey: profileDeviceKey,
            readerKind: 'video-tracks',
            profile: profile,
          ),
        );
      }
    } catch (_) {
      // Stream settings remain available in the secure local store when the
      // server is temporarily offline.
    }
  }

  /// Offline copies use the stable platform key so reader preferences survive
  /// an app reinstall. Online profiles remain device-specific and can be
  /// inspected separately on the server.
  String get _videoProfileDeviceKey =>
      _offlineWork != null ? Platform.operatingSystem : 'video-$deviceId';

  Future<void> _applyVideoTrackPreference(
    VideoTrackPreference preference,
  ) async {
    for (var attempt = 0; attempt < 8; attempt++) {
      final tracks = _player.state.tracks;
      final audio = _findAudioTrack(tracks.audio, preference);
      final subtitle = _findSubtitleTrack(tracks.subtitle, preference);
      if (audio != null) await _player.setAudioTrack(audio);
      if (preference.subtitlesEnabled == false) {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else if (preference.subtitlesEnabled == true && subtitle != null) {
        await _player.setSubtitleTrack(subtitle);
      }
      final needsAudio =
          preference.audioTrackId != null ||
          preference.audioTrackTitle != null ||
          preference.audioLanguage != null;
      final needsSubtitle =
          preference.subtitlesEnabled == true &&
          (preference.subtitleTrackId != null ||
              preference.subtitleTrackTitle != null ||
              preference.subtitleLanguage != null);
      if ((!needsAudio || audio != null) &&
          (!needsSubtitle || subtitle != null)) {
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
    final wantedTitle = _normalizeTrackTitle(preference.audioTrackTitle);
    if (wantedTitle != null) {
      for (final item in tracks) {
        if (_normalizeTrackTitle(item.title) == wantedTitle) return item;
      }
    }
    final wantedLanguage = _canonicalTrackLanguage(preference.audioLanguage);
    if (wantedLanguage == null) return null;
    for (final item in tracks) {
      if (_canonicalTrackLanguage(item.language) == wantedLanguage) return item;
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
    final wantedTitle = _normalizeTrackTitle(preference.subtitleTrackTitle);
    if (wantedTitle != null) {
      for (final item in tracks) {
        if (_normalizeTrackTitle(item.title) == wantedTitle) return item;
      }
    }
    final wantedLanguage = _canonicalTrackLanguage(preference.subtitleLanguage);
    if (wantedLanguage == null) return null;
    for (final item in tracks) {
      if (_canonicalTrackLanguage(item.language) == wantedLanguage) return item;
    }
    return null;
  }

  static String? _normalizeTrackTitle(String? value) {
    final normalized = value?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _canonicalTrackLanguage(String? value) {
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

  Future<void> _pauseForSleepTimer() async {
    if (_closed) return;
    await _player.pause();
    await persist();
  }

  Future<void> _resumeAfterSleepTimerShake() async {
    if (_closed || _playing) return;
    await _player.play();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
