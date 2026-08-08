import '../model/media_position.dart';

final class LibraryPlaybackTrack {
  const LibraryPlaybackTrack({
    required this.fileId,
    required this.relativePath,
    required this.absolutePath,
    required this.title,
    required this.index,
    this.duration,
  });

  final String fileId;
  final String relativePath;
  final String absolutePath;
  final String title;
  final int index;
  final Duration? duration;
}

final class LibraryPlaybackProgress {
  const LibraryPlaybackProgress({
    required this.workId,
    required this.fileId,
    required this.position,
    required this.finished,
    required this.revision,
    required this.updatedAt,
  });

  final String workId;
  final String? fileId;
  final MediaPosition position;
  final bool finished;
  final int revision;
  final DateTime updatedAt;
}
