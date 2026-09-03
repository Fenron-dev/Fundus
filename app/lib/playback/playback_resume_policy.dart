import 'package:fundus_core/fundus_core.dart';

final class PlaybackResumePolicy {
  const PlaybackResumePolicy._();

  /// Resumes old states that were incorrectly marked finished when their
  /// stored position is still clearly before the end.
  static Duration? resumePosition(LibraryPlaybackProgress? progress) {
    if (progress == null) return null;
    final seconds = progress.position.numericValue;
    return resumeTime(
      position: seconds == null
          ? null
          : Duration(milliseconds: (seconds * 1000).round()),
      total: progress.position.total == null
          ? null
          : Duration(milliseconds: (progress.position.total! * 1000).round()),
      finished: progress.finished,
    );
  }

  /// Applies the same finished-state semantics to audio, video and remote
  /// progress records. A stale finished flag is ignored when the saved point
  /// is clearly before the end; a genuinely completed item starts fresh.
  static Duration? resumeTime({
    required Duration? position,
    required Duration? total,
    required bool finished,
  }) {
    if (position == null || position <= Duration.zero) return Duration.zero;
    final incorrectlyFinished =
        finished &&
        (total == null || position + const Duration(seconds: 10) < total);
    if (finished && !incorrectlyFinished) return null;
    return position;
  }

  static bool isAtEnd(Duration position, Duration duration) =>
      duration > Duration.zero &&
      position + const Duration(seconds: 10) >= duration;
}
