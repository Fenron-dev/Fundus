import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/fundus_system_media_session.dart';

void main() {
  test('routes system media actions to the active player', () async {
    final handler = FundusSystemMediaHandler();
    final owner = Object();
    var playCount = 0;
    var pauseCount = 0;
    var previousCount = 0;
    var nextCount = 0;
    final seeks = <Duration>[];

    handler.activate(
      owner,
      FundusSystemMediaControls(
        play: () async => playCount++,
        pause: () async => pauseCount++,
        seek: (position) async => seeks.add(position),
        rewind: () async => seeks.add(const Duration(seconds: -10)),
        fastForward: () async => seeks.add(const Duration(seconds: 30)),
        previous: () async => previousCount++,
        next: () async => nextCount++,
      ),
    );

    await handler.play();
    await handler.pause();
    await handler.seek(const Duration(minutes: 4));
    await handler.rewind();
    await handler.fastForward();
    await handler.skipToPrevious();
    await handler.skipToNext();

    expect(playCount, 1);
    expect(pauseCount, 1);
    expect(previousCount, 1);
    expect(nextCount, 1);
    expect(seeks, [
      const Duration(minutes: 4),
      const Duration(seconds: -10),
      const Duration(seconds: 30),
    ]);
  });

  test('publishes metadata and playback state for active owner only', () {
    final handler = FundusSystemMediaHandler();
    final firstOwner = Object();
    final secondOwner = Object();
    final controls = FundusSystemMediaControls(
      play: () async {},
      pause: () async {},
      seek: (_) async {},
      rewind: () async {},
      fastForward: () async {},
      previous: () async {},
      next: () async {},
    );
    const firstItem = MediaItem(id: 'first', title: 'Erstes Kapitel');
    const staleItem = MediaItem(id: 'stale', title: 'Veraltet');
    const secondItem = MediaItem(id: 'second', title: 'Zweites Kapitel');

    handler.activate(firstOwner, controls);
    handler.update(
      owner: firstOwner,
      item: firstItem,
      position: const Duration(minutes: 2),
      playing: true,
      loading: false,
      speed: 1.25,
      queueIndex: 1,
    );
    handler.activate(secondOwner, controls);
    handler.update(
      owner: firstOwner,
      item: staleItem,
      position: Duration.zero,
      playing: false,
      loading: false,
      speed: 1,
      queueIndex: 0,
    );

    expect(handler.mediaItem.value, firstItem);
    expect(handler.playbackState.value.playing, isTrue);
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(minutes: 2),
    );
    expect(handler.playbackState.value.speed, 1.25);
    expect(handler.playbackState.value.queueIndex, 1);

    handler.update(
      owner: secondOwner,
      item: secondItem,
      position: const Duration(seconds: 12),
      playing: false,
      loading: true,
      speed: 1,
      queueIndex: 0,
    );

    expect(handler.mediaItem.value, secondItem);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.loading,
    );
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('only active owner can deactivate the media session', () {
    final handler = FundusSystemMediaHandler();
    final firstOwner = Object();
    final secondOwner = Object();
    final controls = FundusSystemMediaControls(
      play: () async {},
      pause: () async {},
      seek: (_) async {},
      rewind: () async {},
      fastForward: () async {},
      previous: () async {},
      next: () async {},
    );
    const item = MediaItem(id: 'active', title: 'Aktiv');

    handler.activate(firstOwner, controls);
    handler.activate(secondOwner, controls);
    handler.update(
      owner: secondOwner,
      item: item,
      position: Duration.zero,
      playing: false,
      loading: false,
      speed: 1,
      queueIndex: 0,
    );
    handler.deactivate(firstOwner);
    expect(handler.mediaItem.value, item);

    handler.deactivate(secondOwner);
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
  });
}
