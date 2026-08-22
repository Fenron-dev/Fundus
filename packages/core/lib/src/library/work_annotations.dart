import 'dart:convert';

import '../model/media_position.dart';

final class LibraryBookmark {
  const LibraryBookmark({
    required this.id,
    required this.workId,
    required this.mediaPosition,
    required this.createdAt,
    this.fileId,
    this.label,
    this.note,
  });

  final String id;
  final String workId;
  final String? fileId;
  final MediaPosition mediaPosition;

  /// Compatibility accessor for existing audio-player callers.
  Duration get position => Duration(
    milliseconds: ((mediaPosition.numericValue ?? 0) * 1000).round(),
  );

  String get displayPosition => mediaPosition.displayValue;
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

final class LibraryHighlight {
  const LibraryHighlight({
    required this.id,
    required this.workId,
    required this.mediaPosition,
    required this.quote,
    required this.createdAt,
    this.fileId,
    this.color = '#FFF176',
    this.note,
  });

  final String id;
  final String workId;
  final String? fileId;
  final MediaPosition mediaPosition;
  final String quote;
  final String color;
  final String? note;
  final DateTime createdAt;
}

final class WorkAnnotations {
  const WorkAnnotations({
    this.tags = const [],
    this.note = '',
    this.notes = const [],
    this.bookmarks = const [],
    this.highlights = const [],
  });

  final List<String> tags;

  /// Latest note, retained for compatibility with older callers.
  final String note;
  final List<LibraryNote> notes;
  final List<LibraryBookmark> bookmarks;
  final List<LibraryHighlight> highlights;
}

String exportAnnotationsAsMarkdown({
  required String workTitle,
  required WorkAnnotations annotations,
}) {
  final buffer = StringBuffer('# $workTitle – Fundus-Annotationen\n\n');
  if (annotations.bookmarks.isNotEmpty) {
    buffer.writeln('## Lesezeichen\n');
    for (final bookmark in annotations.bookmarks) {
      buffer.writeln(
        '- **${bookmark.label ?? bookmark.displayPosition}** '
        '(${bookmark.mediaPosition.chapterId ?? 'ohne Kapitel'})',
      );
      if (bookmark.note?.trim().isNotEmpty ?? false) {
        buffer.writeln('  - ${bookmark.note!.trim()}');
      }
    }
    buffer.writeln();
  }
  if (annotations.highlights.isNotEmpty) {
    buffer.writeln('## Hervorhebungen\n');
    for (final highlight in annotations.highlights) {
      buffer.writeln(
        '### ${highlight.mediaPosition.chapterId ?? 'Textstelle'} · '
        '${highlight.mediaPosition.displayValue}\n',
      );
      buffer.writeln('> ${highlight.quote.replaceAll('\n', '\n> ')}\n');
      if (highlight.note?.trim().isNotEmpty ?? false) {
        buffer.writeln(highlight.note!.trim());
        buffer.writeln();
      }
    }
  }
  return buffer.toString();
}

String exportAnnotationsAsJson({
  required String workId,
  required String workTitle,
  required WorkAnnotations annotations,
}) => const JsonEncoder.withIndent('  ').convert({
  'format_version': 1,
  'work_id': workId,
  'work_title': workTitle,
  'exported_at': DateTime.now().toUtc().toIso8601String(),
  'bookmarks': [
    for (final bookmark in annotations.bookmarks)
      {
        'id': bookmark.id,
        'file_id': bookmark.fileId,
        'position': bookmark.mediaPosition.toJson(),
        'label': bookmark.label,
        'note': bookmark.note,
        'created_at': bookmark.createdAt.toUtc().toIso8601String(),
      },
  ],
  'highlights': [
    for (final highlight in annotations.highlights)
      {
        'id': highlight.id,
        'file_id': highlight.fileId,
        'position': highlight.mediaPosition.toJson(),
        'quote': highlight.quote,
        'color': highlight.color,
        'note': highlight.note,
        'created_at': highlight.createdAt.toUtc().toIso8601String(),
      },
  ],
});
