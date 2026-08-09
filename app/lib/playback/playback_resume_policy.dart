import 'package:fundus_core/fundus_core.dart';

final class PlaybackResumePolicy {
  const PlaybackResumePolicy._();

  /// Resumes old states that were incorrectly marked finished when their
  /// stored position is still clearly before the end.
  static Duration? resumePosition(LibraryPlaybackProgress? progress) {
    if (progress == null) return null;
    final seconds = progress.position.numericValue ?? 0;
    final total = progress.position.total;
    final incorrectlyFinished =
        progress.finished && (total == null || seconds + 10 < total);
    if (progress.finished && !incorrectlyFinished) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }

  static bool isAtEnd(Duration position, Duration duration) =>
      duration > Duration.zero &&
      position + const Duration(seconds: 10) >= duration;
}
