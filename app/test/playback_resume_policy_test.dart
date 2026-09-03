import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playback_resume_policy.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  LibraryPlaybackProgress progress({
    required double seconds,
    required double total,
    required bool finished,
  }) => LibraryPlaybackProgress(
    workId: 'work',
    fileId: 'file',
    position: MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: seconds,
      total: total,
      fileId: 'file',
    ),
    finished: finished,
    revision: 1,
    updatedAt: DateTime(2026),
  );

  test('resumes unfinished playback', () {
    expect(
      PlaybackResumePolicy.resumePosition(
        progress(seconds: 3723, total: 50000, finished: false),
      ),
      const Duration(seconds: 3723),
    );
  });

  test('repairs an incorrectly finished state far before the end', () {
    expect(
      PlaybackResumePolicy.resumePosition(
        progress(seconds: 42, total: 50000, finished: true),
      ),
      const Duration(seconds: 42),
    );
  });

  test('completed work starts from the beginning', () {
    expect(
      PlaybackResumePolicy.resumePosition(
        progress(seconds: 49995, total: 50000, finished: true),
      ),
      isNull,
    );
  });

  test('completion requires a real position near duration', () {
    expect(
      PlaybackResumePolicy.isAtEnd(
        const Duration(seconds: 3),
        const Duration(hours: 16),
      ),
      isFalse,
    );
    expect(
      PlaybackResumePolicy.isAtEnd(
        const Duration(minutes: 59, seconds: 55),
        const Duration(hours: 1),
      ),
      isTrue,
    );
  });

  test('video and remote records use the same finished-state policy', () {
    expect(
      PlaybackResumePolicy.resumeTime(
        position: const Duration(minutes: 12),
        total: const Duration(hours: 1),
        finished: false,
      ),
      const Duration(minutes: 12),
    );
    expect(
      PlaybackResumePolicy.resumeTime(
        position: const Duration(minutes: 12),
        total: const Duration(hours: 1),
        finished: true,
      ),
      const Duration(minutes: 12),
    );
    expect(
      PlaybackResumePolicy.resumeTime(
        position: const Duration(minutes: 59, seconds: 55),
        total: const Duration(hours: 1),
        finished: true,
      ),
      isNull,
    );
  });
}
