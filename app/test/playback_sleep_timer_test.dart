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

  test('schedules a timer for an absolute time', () {
    final timer = PlaybackSleepTimer(onElapsed: () async {});
    final target = DateTime.now().add(const Duration(hours: 2));

    timer.scheduleAt(target);

    expect(timer.mode, PlaybackSleepTimerMode.atTime);
    expect(timer.endsAt, target);
    expect(timer.remaining, isNotNull);
    timer.dispose();
  });

  test('chapter end elapses only the matching mode', () async {
    var elapsed = 0;
    final timer = PlaybackSleepTimer(onElapsed: () async => elapsed++);
    timer.scheduleEndOfChapter();

    expect(await timer.chapterEnded(), isTrue);
    expect(elapsed, 1);
    expect(timer.mode, PlaybackSleepTimerMode.off);
    expect(await timer.chapterEnded(), isFalse);
    expect(elapsed, 1);
    timer.dispose();
  });

  test('shake restart is observable and limited to duration mode', () {
    final timer = PlaybackSleepTimer(onElapsed: () async {});
    timer.schedule(const Duration(minutes: 15));

    expect(timer.restart(fromShake: true), isTrue);
    expect(timer.shakeRestartCount, 1);
    timer.scheduleEndOfTrack();
    expect(timer.restart(fromShake: true), isFalse);
    expect(timer.shakeRestartCount, 1);
    timer.dispose();
  });

  test('shake can restart a duration timer shortly after it elapsed', () async {
    final elapsed = Completer<void>();
    final timer = PlaybackSleepTimer(
      onElapsed: () async => elapsed.complete(),
      shakeRestartGracePeriod: const Duration(milliseconds: 200),
    );
    addTearDown(timer.dispose);

    timer.schedule(const Duration(milliseconds: 20));
    await elapsed.future.timeout(const Duration(seconds: 1));

    expect(timer.active, isFalse);
    expect(timer.shakeRestartAvailable, isTrue);
    expect(timer.restart(), isFalse);
    expect(timer.restart(fromShake: true), isTrue);
    expect(timer.active, isTrue);
    expect(timer.configuredDuration, const Duration(milliseconds: 20));
  });

  test('shake restart expires after the grace period', () async {
    final elapsed = Completer<void>();
    final timer = PlaybackSleepTimer(
      onElapsed: () async => elapsed.complete(),
      shakeRestartGracePeriod: const Duration(milliseconds: 30),
    );
    addTearDown(timer.dispose);

    timer.schedule(const Duration(milliseconds: 10));
    await elapsed.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(timer.shakeRestartAvailable, isFalse);
    expect(timer.configuredDuration, isNull);
    expect(timer.restart(fromShake: true), isFalse);
  });

  test('manual cancel clears the post-expiry shake window', () async {
    final elapsed = Completer<void>();
    final timer = PlaybackSleepTimer(
      onElapsed: () async => elapsed.complete(),
      shakeRestartGracePeriod: const Duration(seconds: 1),
    );
    addTearDown(timer.dispose);

    timer.schedule(const Duration(milliseconds: 10));
    await elapsed.future.timeout(const Duration(seconds: 1));
    timer.cancel();

    expect(timer.shakeRestartAvailable, isFalse);
    expect(timer.restart(fromShake: true), isFalse);
  });
}
