import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:media_kit/media_kit.dart';

import 'playback_autosave_settings.dart';

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
        if (!value) unawaited(persist());
      }),
      _player.stream.position.listen((value) {
        _position = value;
        notifyListeners();
        final interval = PlaybackAutosaveSettings.interval(
          _work?.kind ?? 'video',
        );
        if (_playing &&
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
        _currentIndex = playlist.index.clamp(0, _tracks.length - 1);
        _position = Duration.zero;
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
          (progress?.position.kind == MediaPositionKind.time
              ? Duration(
                  milliseconds: ((progress?.position.numericValue ?? 0) * 1000)
                      .round(),
                )
              : Duration.zero);
      if (resume > Duration.zero) {
        await _player.seek(resume);
        _position = resume;
        notifyListeners();
      }
      // Seek before starting playback. Some containers emit a fresh zero
      // position when playback starts directly after opening the playlist.
      await _player.play();
    } catch (error) {
      _loading = false;
      _ready = false;
      _error = error.toString();
      notifyListeners();
    }
  }

  Future<void> persist({bool finished = false}) async {
    if (!_ready || _persisting || _library == null || track == null) return;
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

  Future<void> close() async {
    if (_closed) return;
    await persist();
    await _player.pause();
    _ready = false;
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
