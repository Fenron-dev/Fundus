import 'dart:async';

import 'package:flutter/foundation.dart';

enum PlaybackSleepTimerMode { off, duration, endOfTrack }

final class PlaybackSleepTimer extends ChangeNotifier {
  PlaybackSleepTimer({required Future<void> Function() onElapsed})
    : _onElapsed = onElapsed;

  final Future<void> Function() _onElapsed;

  Timer? _elapsedTimer;
  Timer? _ticker;
  PlaybackSleepTimerMode _mode = PlaybackSleepTimerMode.off;
  DateTime? _endsAt;
  Duration? _configuredDuration;
  bool _disposed = false;

  PlaybackSleepTimerMode get mode => _mode;
  bool get active => _mode != PlaybackSleepTimerMode.off;
  DateTime? get endsAt => _endsAt;
  Duration? get configuredDuration => _configuredDuration;
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
    _endsAt = DateTime.now().add(duration);
    _elapsedTimer = Timer(duration, () => unawaited(_elapse()));
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed) notifyListeners();
    });
    notifyListeners();
  }

  void scheduleEndOfTrack() {
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.endOfTrack;
    _configuredDuration = null;
    _endsAt = null;
    notifyListeners();
  }

  /// Starts the configured fixed duration again. This is also the hook used by
  /// the optional mobile shake gesture later on.
  bool restart() {
    final duration = _configuredDuration;
    if (_mode != PlaybackSleepTimerMode.duration || duration == null) {
      return false;
    }
    schedule(duration);
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
    if (changed && !_disposed) notifyListeners();
  }

  Future<void> _elapse() async {
    if (!active) return;
    _cancelTimers();
    _mode = PlaybackSleepTimerMode.off;
    _endsAt = null;
    if (!_disposed) notifyListeners();
    await _onElapsed();
  }

  void _cancelTimers() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    super.dispose();
  }
}
