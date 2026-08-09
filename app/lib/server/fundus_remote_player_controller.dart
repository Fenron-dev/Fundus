import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'fundus_remote_client.dart';
import 'fundus_remote_stream_proxy.dart';

final class FundusRemotePlayerController extends ChangeNotifier {
  FundusRemotePlayerController({
    required this.deviceId,
    FundusRemoteClient client = const FundusRemoteClient(),
  }) : _client = client,
       _player = Player() {
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
        if (completed && _currentIndex == _tracks.length - 1) {
          final finished =
              _duration > Duration.zero &&
              _position + const Duration(seconds: 10) >= _duration;
          unawaited(persist(finished: finished));
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
  final Player _player;
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
  DateTime? _lastPersistedAt;
  String? _error;

  FundusRemoteWork? get work => _work;
  FundusRemoteTrack? get track =>
      _tracks.isEmpty ? null : _tracks[_currentIndex];
  List<FundusRemoteTrack> get tracks => List.unmodifiable(_tracks);
  int get currentIndex => _currentIndex;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get loading => _loading;
  String? get error => _error;

  Future<void> open(
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work,
  ) async {
    if (_closed) return;
    await persist();
    await _player.pause();
    await _proxy?.close();
    _proxy = null;
    _ready = false;
    _loading = true;
    _error = null;
    _server = server;
    _library = library;
    _work = work;
    _tracks = const [];
    _currentIndex = 0;
    _position = Duration.zero;
    notifyListeners();
    try {
      final detail = await _client.work(server, library.id, work);
      final progress = await _client.progress(server, library.id, work.id);
      if (detail.tracks.isEmpty) {
        throw StateError('Dieses Werk enthält keine abspielbaren Dateien.');
      }
      _tracks = detail.tracks;
      final resumeIndex = progress?.fileId == null
          ? -1
          : _tracks.indexWhere((item) => item.id == progress!.fileId);
      if (resumeIndex >= 0) _currentIndex = resumeIndex;
      final proxy = await FundusRemoteStreamProxy.start(
        server: server,
        libraryId: library.id,
        tracks: _tracks,
        client: _client,
      );
      _proxy = proxy;
      await _player.open(
        Playlist(
          proxy.urls.map((uri) => Media(uri.toString())).toList(),
          index: _currentIndex,
        ),
        play: false,
      );
      _ready = true;
      _loading = false;
      _lastPersistedAt = DateTime.now();
      notifyListeners();
      await _player.play();
      if (progress != null &&
          !progress.finished &&
          progress.position > Duration.zero) {
        await _player.seek(progress.position);
        _position = progress.position;
        notifyListeners();
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
      await _player.play();
    }
  }

  Future<void> seek(Duration value) => _player.seek(value);

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
      await _client.saveProgress(
        server,
        libraryId: library.id,
        workId: work.id,
        fileId: currentTrack.id,
        position: _position,
        duration: effectiveDuration,
        finished: finished,
        deviceId: deviceId,
        operationId: _operationId(),
      );
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
    await _player.dispose();
    await _proxy?.close();
    _proxy = null;
  }

  String _operationId() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return 'remote-${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
