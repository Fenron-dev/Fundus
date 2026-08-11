import 'dart:async';

import 'package:flutter/foundation.dart';

enum PlaybackSleepTimerMode { off, duration, atTime, endOfChapter, endOfTrack }

final class PlaybackSleepTimer extends ChangeNotifier {
  PlaybackSleepTimer({
    required Future<void> Function() onElapsed,
    this.shakeRestartGracePeriod = const Duration(minutes: 2),
  }) : _onElapsed = onElapsed;

  final Future<void> Function() _onElapsed;
  final Duration shakeRestartGracePeriod;

  Timer? _elapsedTimer;
  Timer? _ticker;
  Timer? _shakeGraceTimer;
  PlaybackSleepTimerMode _mode = PlaybackSleepTimerMode.off;
  DateTime? _endsAt;
  DateTime? _shakeRestartUntil;
  Duration? _configuredDuration;
  int _shakeRestartCount = 0;
  bool _disposed = false;

  PlaybackSleepTimerMode get mode => _mode;
  bool get active => _mode != PlaybackSleepTimerMode.off;
  DateTime? get endsAt => _endsAt;
  Duration? get configuredDuration => _configuredDuration;
  DateTime? get shakeRestartUntil => _shakeRestartUntil;
  int get shakeRestartCount => _shakeRestartCount;
  bool get shakeRestartAvailable {
    if (_mode == PlaybackSleepTimerMode.duration) return true;
    final until = _shakeRestartUntil;
    return _mode == PlaybackSleepTimerMode.off &&
        until != null &&
        !DateTime.now().isAfter(until);
  }

  Duration? get remaining {
    final end = _endsAt;
    if (end == null) return null;
    final value = end.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  void schedule(Duration duration) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(duration, 'duration', 'Muss positiv sein.');
    }
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.duration;
    _configuredDuration = duration;
    _shakeRestartUntil = null;
    _endsAt = DateTime.now().add(duration);
    _elapsedTimer = Timer(duration, () => unawaited(_elapse()));
    _startTicker();
    notifyListeners();
  }

  void scheduleAt(DateTime time) {
    final duration = time.difference(DateTime.now());
    if (duration <= Duration.zero) {
      throw ArgumentError.value(time, 'time', 'Muss in der Zukunft liegen.');
    }
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.atTime;
    _configuredDuration = null;
    _shakeRestartUntil = null;
    _endsAt = time;
    _elapsedTimer = Timer(duration, () => unawaited(_elapse()));
    _startTicker();
    notifyListeners();
  }

  void scheduleEndOfChapter() {
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.endOfChapter;
    _configuredDuration = null;
    _shakeRestartUntil = null;
    _endsAt = null;
    notifyListeners();
  }

  void scheduleEndOfTrack() {
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.endOfTrack;
    _configuredDuration = null;
    _shakeRestartUntil = null;
    _endsAt = null;
    notifyListeners();
  }

  /// Starts the configured fixed duration again. This is also the hook used by
  /// the optional mobile shake gesture later on.
  bool restart({bool fromShake = false}) {
    final duration = _configuredDuration;
    final activeDuration = _mode == PlaybackSleepTimerMode.duration;
    final expiredGrace = fromShake && shakeRestartAvailable && !activeDuration;
    if ((!activeDuration && !expiredGrace) || duration == null) {
      return false;
    }
    if (fromShake) _shakeRestartCount++;
    schedule(duration);
    return true;
  }

  Future<bool> chapterEnded() async {
    if (_mode != PlaybackSleepTimerMode.endOfChapter) return false;
    await _elapse();
    return true;
  }

  Future<bool> trackEnded() async {
    if (_mode != PlaybackSleepTimerMode.endOfTrack) return false;
    await _elapse();
    return true;
  }

  void cancel() {
    final changed = active;
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.off;
    _configuredDuration = null;
    _endsAt = null;
    _shakeRestartUntil = null;
    if (changed && !_disposed) notifyListeners();
  }

  Future<void> _elapse() async {
    if (!active) return;
    final allowShakeRestart =
        _mode == PlaybackSleepTimerMode.duration &&
        _configuredDuration != null &&
        shakeRestartGracePeriod > Duration.zero;
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.off;
    _endsAt = null;
    if (allowShakeRestart) {
      _shakeRestartUntil = DateTime.now().add(shakeRestartGracePeriod);
      _shakeGraceTimer = Timer(shakeRestartGracePeriod, _expireShakeGrace);
    } else {
      _configuredDuration = null;
      _shakeRestartUntil = null;
    }
    if (!_disposed) notifyListeners();
    await _onElapsed();
  }

  void _expireShakeGrace() {
    _shakeGraceTimer = null;
    _shakeRestartUntil = null;
    _configuredDuration = null;
    if (!_disposed) notifyListeners();
  }

  void _cancelTimers() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _ticker?.cancel();
    _ticker = null;
    _shakeGraceTimer?.cancel();
    _shakeGraceTimer = null;
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    super.dispose();
  }
}
