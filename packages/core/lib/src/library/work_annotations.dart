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

final class LibraryNote {
  const LibraryNote({
    required this.id,
    required this.markdown,
    required this.createdAt,
  });

  final String id;
  final String markdown;
  final DateTime createdAt;
}

final class WorkAnnotations {
  const WorkAnnotations({
    this.tags = const [],
    this.note = '',
    this.notes = const [],
    this.bookmarks = const [],
  });

  final List<String> tags;

  /// Latest note, retained for compatibility with older callers.
  final String note;
  final List<LibraryNote> notes;
  final List<LibraryBookmark> bookmarks;
}
