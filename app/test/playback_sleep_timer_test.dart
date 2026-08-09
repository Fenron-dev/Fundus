import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playback_sleep_timer.dart';

void main() {
  test('fixed sleep timer invokes callback and switches off', () async {
    final elapsed = Completer<void>();
    final timer = PlaybackSleepTimer(onElapsed: () async => elapsed.complete());
    addTearDown(timer.dispose);

    timer.schedule(const Duration(milliseconds: 20));

    await elapsed.future.timeout(const Duration(seconds: 1));
    expect(timer.mode, PlaybackSleepTimerMode.off);
    expect(timer.active, isFalse);
  });

  test('cancel prevents fixed timer callback', () async {
    var elapsed = false;
    final timer = PlaybackSleepTimer(onElapsed: () async => elapsed = true);
    addTearDown(timer.dispose);

    timer.schedule(const Duration(milliseconds: 20));
    timer.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(elapsed, isFalse);
    expect(timer.mode, PlaybackSleepTimerMode.off);
  });

  test('end-of-track mode waits for track transition', () async {
    var elapsed = 0;
    final timer = PlaybackSleepTimer(onElapsed: () async => elapsed++);
    addTearDown(timer.dispose);

    timer.scheduleEndOfTrack();
    expect(timer.mode, PlaybackSleepTimerMode.endOfTrack);
    expect(await timer.trackEnded(), isTrue);

    expect(elapsed, 1);
    expect(await timer.trackEnded(), isFalse);
    expect(elapsed, 1);
  });

  test('restart extends the configured fixed duration', () async {
    final elapsed = Completer<void>();
    final timer = PlaybackSleepTimer(onElapsed: () async => elapsed.complete());
    addTearDown(timer.dispose);

    timer.schedule(const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(timer.restart(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(elapsed.isCompleted, isFalse);
    await elapsed.future.timeout(const Duration(seconds: 1));
  });
}
