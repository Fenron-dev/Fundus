import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playback_shake_restart.dart';
import 'package:fundus/playback/playback_sleep_timer.dart';

void main() {
  test('shake restarts an active duration timer once per cooldown', () async {
    final events = StreamController<PlaybackAcceleration>.broadcast();
    final timer = PlaybackSleepTimer(onElapsed: () async {});
    timer.schedule(const Duration(minutes: 30));
    var confirmations = 0;
    final controller = PlaybackShakeRestartController(
      timer: timer,
      events: events.stream,
      supported: true,
      loadConfiguration: () async => const PlaybackShakeConfiguration(
        enabled: true,
        threshold: 10,
        cooldown: Duration(minutes: 1),
      ),
      confirm: () async => confirmations++,
    );
    await Future<void>.delayed(Duration.zero);

    events.add(const PlaybackAcceleration(12, 0, 0));
    await Future<void>.delayed(Duration.zero);
    events.add(const PlaybackAcceleration(0, 0, 0));
    events.add(const PlaybackAcceleration(12, 0, 0));
    await Future<void>.delayed(Duration.zero);

    expect(controller.restartCount, 1);
    expect(confirmations, 1);
    await controller.dispose();
    timer.dispose();
    await events.close();
  });

  test('shake does not alter end-of-track mode', () async {
    final events = StreamController<PlaybackAcceleration>.broadcast();
    final timer = PlaybackSleepTimer(onElapsed: () async {});
    timer.scheduleEndOfTrack();
    final controller = PlaybackShakeRestartController(
      timer: timer,
      events: events.stream,
      supported: true,
      loadConfiguration: () async =>
          const PlaybackShakeConfiguration(enabled: true, threshold: 10),
    );
    await Future<void>.delayed(Duration.zero);

    events.add(const PlaybackAcceleration(12, 0, 0));
    await Future<void>.delayed(Duration.zero);

    expect(controller.restartCount, 0);
    expect(timer.mode, PlaybackSleepTimerMode.endOfTrack);
    await controller.dispose();
    timer.dispose();
    await events.close();
  });
}
