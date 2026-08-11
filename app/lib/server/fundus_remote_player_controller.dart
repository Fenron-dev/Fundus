import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../diagnostics/fundus_diagnostics.dart';
import '../playback/playback_sleep_timer.dart';
import '../playback/playback_conflict_settings.dart';
import 'fundus_remote_client.dart';
import 'fundus_remote_stream_proxy.dart';
import 'fundus_offline_store.dart';

typedef FundusRemoteServerResolver =
    Future<FundusRemoteServer> Function(FundusRemoteServer server);

final class FundusRemotePlayerController extends ChangeNotifier {
  FundusRemotePlayerController({
    required this.deviceId,
    FundusRemoteClient client = const FundusRemoteClient(),
    FundusOfflineStore? offlineStore,
    this.onConflict,
    this.serverResolver,
  }) : _client = client,
       _offlineStore = offlineStore ?? FundusOfflineStore(),
       _player = Player() {
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
        final last = _lastPersistedAt;
        if (_ready && _playing && last != null) {
          if (DateTime.now().difference(last) >= const Duration(seconds: 5)) {
            unawaited(persist());
          }
        }
      }),
      _player.stream.duration.listen((value) {
        _duration = value;
        notifyListeners();
      }),
      _player.stream.playlist.listen((playlist) {
        if (_tracks.isEmpty) return;
        _currentIndex = playlist.index.clamp(0, _tracks.length - 1);
        _position = Duration.zero;
        notifyListeners();
      }),
      _player.stream.completed.listen((completed) {
        if (!completed) return;
        if (_currentIndex == _tracks.length - 1) {
          final finished =
              _duration > Duration.zero &&
              _position + const Duration(seconds: 10) >= _duration;
          unawaited(persist(finished: finished));
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
  final FundusRemoteClient _client;
  final FundusOfflineStore _offlineStore;
  final PlaybackConflictResolver? onConflict;
  final FundusRemoteServerResolver? serverResolver;
  final Player _player;
  late final PlaybackSleepTimer _sleepTimer;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  FundusRemoteStreamProxy? _proxy;
  FundusRemoteServer? _server;
  FundusRemoteLibrary? _library;
  FundusRemoteWork? _work;
  List<FundusRemoteTrack> _tracks = const [];
  int _currentIndex = 0;
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

  FundusRemoteWork? get work => _work;
  FundusRemoteTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  List<FundusRemoteTrack> get tracks => List.unmodifiable(_tracks);
  String? get offlineCoverPath => _offlineWork?.coverPath;
  int get currentIndex => _currentIndex;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get loading => _loading;
  double get rate => _rate;
  String? get error => _error;
  PlaybackSleepTimer get sleepTimer => _sleepTimer;

  Future<void> open(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    FundusOfflineWork? offlineWork,
  }) async {
    if (_closed) return;
    await persist();
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
    _currentIndex = 0;
    _position = Duration.zero;
    notifyListeners();
    try {
      final tracks = offlineWork == null
          ? (await _withReconnect(
              (active) => _client.work(active, library.id, work),
            )).tracks
          : [
              for (final track in offlineWork.tracks)
                FundusRemoteTrack(
                  id: track.id,
                  title: track.title,
                  position: track.position,
                  duration: track.duration,
                ),
            ];
      FundusRemoteProgress? localProgress;
      if (offlineWork != null) {
        localProgress = await _offlineStore.loadProgress(
          serverId: server.id,
          libraryId: library.id,
          workId: work.id,
        );
      }
      FundusRemoteProgress? serverProgress;
      try {
        serverProgress = await _withReconnect(
          (active) => _client.progress(active, library.id, work.id),
        );
      } catch (_) {
        serverProgress = null;
      }
      if (tracks.isEmpty) {
        throw StateError('Dieses Werk enthält keine abspielbaren Dateien.');
      }
      _tracks = tracks;
      var progress = serverProgress ?? localProgress;
      if (localProgress != null && serverProgress != null) {
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
          final choice = await onConflict!(
            PlaybackResumeConflict(
              currentPosition: localProgress.position,
              incomingPosition: serverProgress.position,
              currentTrack: localIndex >= 0
                  ? tracks[localIndex].title
                  : 'Lokale Datei',
              incomingTrack: serverIndex >= 0
                  ? tracks[serverIndex].title
                  : 'Gespeicherte Datei',
              incomingSource: 'Server / anderes Gerät',
            ),
          );
          if (choice == PlaybackConflictChoice.keepCurrent) {
            progress = localProgress;
          }
        }
      }
      _progressRevision = max(
        localProgress?.revision ?? 0,
        serverProgress?.revision ?? 0,
      );
      final resumeIndex = progress?.fileId == null
          ? -1
          : _tracks.indexWhere((item) => item.id == progress!.fileId);
      if (resumeIndex >= 0) _currentIndex = resumeIndex;
      final List<Media> media;
      if (offlineWork == null) {
        final proxy = await FundusRemoteStreamProxy.start(
          server: _server ?? server,
          libraryId: library.id,
          tracks: _tracks,
          client: _client,
        );
        _proxy = proxy;
        media = proxy.urls.map((uri) => Media(uri.toString())).toList();
      } else {
        media = offlineWork.tracks.map((track) => Media(track.path)).toList();
      }
      await _player.open(Playlist(media, index: _currentIndex), play: false);
      _ready = true;
      _loading = false;
      _lastPersistedAt = DateTime.now();
      notifyListeners();
      await _player.play();
      if (progress != null &&
          !progress.finished &&
          progress.position > Duration.zero) {
        _position = await _seekAndVerify(progress.position);
        notifyListeners();
        unawaited(
          FundusDiagnostics.instance.record('remote.resume_applied', {
            'work_id': work.id,
            'file_id': track?.id,
            'position_ms': progress.position.inMilliseconds,
            'player_position_ms': _position.inMilliseconds,
            'offline': offlineWork != null,
          }),
        );
      }
    } catch (error) {
      _loading = false;
      _ready = false;
      _error = 'Remote-Wiedergabe konnte nicht gestartet werden: $error';
      notifyListeners();
    }
  }

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
    if (latest == null || latest.revision <= _progressRevision) return;
    final targetIndex = latest.fileId == null
        ? -1
        : _tracks.indexWhere((track) => track.id == latest!.fileId);
    final differs =
        targetIndex >= 0 && targetIndex != _currentIndex ||
        (latest.position - _position).abs() > const Duration(seconds: 10);
    if (differs && onConflict != null) {
      final choice = await onConflict!(
        PlaybackResumeConflict(
          currentPosition: _position,
          incomingPosition: latest.position,
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
      await _player.jump(targetIndex);
      _currentIndex = targetIndex;
    }
    if (!latest.finished && latest.position > Duration.zero) {
      _position = await _seekAndVerify(latest.position);
    }
    _progressRevision = latest.revision;
    notifyListeners();
  }

  Future<void> seek(Duration value) => _player.seek(value);

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

  Future<void> next() async {
    if (!_ready || _currentIndex >= _tracks.length - 1) return;
    await persist();
    await _player.next();
  }

  Future<void> previous() async {
    if (!_ready) return;
    if (_position > const Duration(seconds: 5)) {
      await _player.seek(Duration.zero);
    } else if (_currentIndex > 0) {
      await persist();
      await _player.previous();
    }
  }

  Future<void> jumpToTrack(int index) async {
    if (!_ready || index < 0 || index >= _tracks.length) return;
    await persist();
    await _player.jump(index);
  }

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
    } catch (_) {
      _error = 'Fortschritt konnte nicht zum Server übertragen werden.';
      notifyListeners();
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

  String _operationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return 'remote-${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  Future<Duration> _seekAndVerify(Duration target) async {
    var actual = _player.state.position;
    for (var attempt = 1; attempt <= 6; attempt++) {
      await _player.seek(target);
      await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      actual = _player.state.position;
      if ((actual - target).abs() <= const Duration(seconds: 2)) return actual;
    }
    throw StateError('Fortsetzungsposition konnte nicht gesetzt werden.');
  }

  Future<void> _pauseForSleepTimer() async {
    if (_closed) return;
    await _player.pause();
    await persist();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
