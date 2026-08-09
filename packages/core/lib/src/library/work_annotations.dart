final class LibraryBookmark {
  const LibraryBookmark({
    required this.id,
    required this.workId,
    required this.position,
    required this.createdAt,
    this.fileId,
    this.label,
    this.note,
  });

  final String id;
  final String workId;
  final String? fileId;
  final Duration position;
  final String? label;
  final String? note;
  final DateTime createdAt;
}

final class WorkAnnotations {
  const WorkAnnotations({
    this.tags = const [],
    this.note = '',
    this.bookmarks = const [],
  });

  final List<String> tags;
  final String note;
  final List<LibraryBookmark> bookmarks;
}
