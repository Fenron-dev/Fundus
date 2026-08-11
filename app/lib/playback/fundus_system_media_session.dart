import 'dart:io';

import 'package:audio_service/audio_service.dart';

typedef SystemMediaAction = Future<void> Function();
typedef SystemMediaSeekAction = Future<void> Function(Duration position);

final class FundusSystemMediaControls {
  const FundusSystemMediaControls({
    required this.play,
    required this.pause,
    required this.seek,
    required this.rewind,
    required this.fastForward,
    required this.previous,
    required this.next,
  });

  final SystemMediaAction play;
  final SystemMediaAction pause;
  final SystemMediaSeekAction seek;
  final SystemMediaAction rewind;
  final SystemMediaAction fastForward;
  final SystemMediaAction previous;
  final SystemMediaAction next;
}

/// Connects the active Fundus player to Android's media notification,
/// lock-screen controls and hardware media buttons.
final class FundusSystemMediaSession {
  FundusSystemMediaSession._();

  static final instance = FundusSystemMediaSession._();

  FundusSystemMediaHandler? _handler;

  Future<void> initialize() async {
    if (!Platform.isAndroid || _handler != null) return;
    _handler = await AudioService.init(
      builder: FundusSystemMediaHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'dev.fundus.playback',
        androidNotificationChannelName: 'Medienwiedergabe',
        androidNotificationChannelDescription:
            'Steuerung laufender Hörbücher und anderer Medien.',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        fastForwardInterval: Duration(seconds: 30),
        rewindInterval: Duration(seconds: 10),
      ),
    );
  }

  void activate(Object owner, FundusSystemMediaControls controls) {
    _handler?.activate(owner, controls);
  }

  void update({
    required Object owner,
    required String id,
    required String title,
    required String album,
    required String artist,
    required Duration position,
    required Duration duration,
    required bool playing,
    required bool loading,
    required double speed,
    required int queueIndex,
    Uri? artUri,
  }) {
    _handler?.update(
      owner: owner,
      item: MediaItem(
        id: id,
        title: title,
        album: album,
        artist: artist,
        duration: duration > Duration.zero ? duration : null,
        artUri: artUri,
      ),
      position: position,
      playing: playing,
      loading: loading,
      speed: speed,
      queueIndex: queueIndex,
    );
  }

  void deactivate(Object owner) => _handler?.deactivate(owner);
}

/// Public for focused unit tests; application code uses the singleton above.
final class FundusSystemMediaHandler extends BaseAudioHandler with SeekHandler {
  Object? _owner;
  FundusSystemMediaControls? _controls;

  void activate(Object owner, FundusSystemMediaControls controls) {
    _owner = owner;
    _controls = controls;
  }

  void update({
    required Object owner,
    required MediaItem item,
    required Duration position,
    required bool playing,
    required bool loading,
    required double speed,
    required int queueIndex,
  }) {
    if (!identical(owner, _owner)) return;
    mediaItem.add(item);
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
        ],
        androidCompactActionIndices: const [1, 2, 3],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekBackward,
          MediaAction.seekForward,
        },
        processingState: loading
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
        speed: speed,
        queueIndex: queueIndex,
      ),
    );
  }

  void deactivate(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _controls = null;
    mediaItem.add(null);
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> play() async => _controls?.play();

  @override
  Future<void> pause() async => _controls?.pause();

  @override
  Future<void> seek(Duration position) async => _controls?.seek(position);

  @override
  Future<void> rewind() async => _controls?.rewind();

  @override
  Future<void> fastForward() async => _controls?.fastForward();

  @override
  Future<void> skipToPrevious() async => _controls?.previous();

  @override
  Future<void> skipToNext() async => _controls?.next();

  @override
  Future<void> stop() async {
    await _controls?.pause();
    await super.stop();
  }
}
