import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import 'reflow_text_reader.dart';
import 'publication_reader_settings.dart';

bool supportsInternalEpubReader(String path) =>
    p.extension(path).toLowerCase() == '.epub';

Future<void> showEpubReader(
  BuildContext context, {
  required String path,
  MediaPosition? initialPosition,
  String? fileId,
  String? relativePath,
  ReflowReaderProfile initialProfile = const ReflowReaderProfile(),
  void Function(MediaPosition position)? onPositionChanged,
  void Function(ReflowReaderProfile profile)? onProfileChanged,
  Future<void> Function(ReflowReaderProfile profile)? onSaveAsDefault,
  Future<ReflowReaderProfile> Function()? onResetWorkProfile,
  List<LibraryBookmark> initialBookmarks = const [],
  List<LibraryHighlight> initialHighlights = const [],
  ReflowAddBookmark? onAddBookmark,
  ReflowAddHighlight? onAddHighlight,
  ReflowDeleteAnnotation? onDeleteBookmark,
  ReflowDeleteAnnotation? onDeleteHighlight,
  Future<void> Function()? onExportAnnotations,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var loadingVisible = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AlertDialog(
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(width: 20),
          Flexible(child: Text('EPUB wird sicher eingelesen …')),
        ],
      ),
    ),
  );
  late final EpubPublication publication;
  try {
    publication = await Isolate.run(
      () => const EpubPackageAdapter().openFile(path),
    );
  } finally {
    if (loadingVisible && navigator.mounted && navigator.canPop()) {
      navigator.pop();
      loadingVisible = false;
    }
  }
  if (!context.mounted) return;

  final chapters = publication.chapters;
  var bookmarks = List<LibraryBookmark>.of(initialBookmarks);
  var highlights = List<LibraryHighlight>.of(initialHighlights);
  final documentCache = <int, ReflowDocument>{};
  ReflowDocument documentFor(int index) => documentCache.putIfAbsent(
    index,
    () => ReflowDocument.parse(
      chapters[index].html,
      format: ReflowSourceFormat.html,
    ),
  );

  Future<List<ReflowReaderSearchResult>> searchBook(String query) async {
    final results = <ReflowReaderSearchResult>[];
    for (
      var index = 0;
      index < chapters.length && results.length < 200;
      index++
    ) {
      final chapter = chapters[index];
      final document = documentFor(index);
      for (final match in document.search(query, limit: 200 - results.length)) {
        results.add(
          ReflowReaderSearchResult(
            chapterIndex: index,
            chapterTitle: chapter.title,
            position: document.positionFor(
              paragraphIndex: match.paragraphIndex,
              innerOffset: match.innerOffset,
              fileId: fileId,
              chapterId: chapter.id,
              key: relativePath,
            ),
            snippet: match.snippet,
          ),
        );
      }
    }
    return results;
  }

  var readerProfile = initialProfile;
  var chapterIndex = initialPosition?.chapterId == null
      ? 0
      : chapters.indexWhere(
          (chapter) =>
              chapter.id == initialPosition!.chapterId ||
              chapter.title == initialPosition.chapterId,
        );
  if (chapterIndex < 0) chapterIndex = 0;
  MediaPosition? chapterPosition = initialPosition;
  while (context.mounted) {
    final chapter = chapters[chapterIndex];
    final document = documentFor(chapterIndex);
    final result = await showReflowDocumentReader(
      context,
      document: document,
      title: chapter.title,
      initialPosition:
          chapterPosition?.chapterId == chapter.id ||
              chapterPosition?.chapterId == chapter.title
          ? chapterPosition
          : null,
      fileId: fileId,
      relativePath: relativePath,
      positionChapterId: chapter.id,
      chapterIndex: chapterIndex,
      chapterCount: chapters.length,
      chapterTitles: [
        for (final item in chapters)
          '${item.depth == 0 ? '' : '${List.filled(item.depth, '  ').join()}↳ '}${item.title}',
      ],
      chapterIds: [for (final item in chapters) item.id],
      hasPreviousChapter: chapterIndex > 0,
      hasNextChapter: chapterIndex + 1 < chapters.length,
      initialProfile: readerProfile,
      onPositionChanged: onPositionChanged,
      onProfileChanged: (updated) {
        readerProfile = updated;
        onProfileChanged?.call(updated);
      },
      onSaveAsDefault: onSaveAsDefault,
      onResetWorkProfile: onResetWorkProfile,
      onSearch: searchBook,
      initialBookmarks: bookmarks,
      initialHighlights: highlights,
      onAddBookmark: onAddBookmark == null
          ? null
          : (position, label) async {
              final annotations = await onAddBookmark(position, label);
              bookmarks = List.of(annotations.bookmarks);
              highlights = List.of(annotations.highlights);
              return annotations;
            },
      onAddHighlight: onAddHighlight == null
          ? null
          : (position, quote, color, note) async {
              final annotations = await onAddHighlight(
                position,
                quote,
                color,
                note,
              );
              bookmarks = List.of(annotations.bookmarks);
              highlights = List.of(annotations.highlights);
              return annotations;
            },
      onDeleteBookmark: onDeleteBookmark == null
          ? null
          : (id) async {
              final annotations = await onDeleteBookmark(id);
              bookmarks = List.of(annotations.bookmarks);
              highlights = List.of(annotations.highlights);
              return annotations;
            },
      onDeleteHighlight: onDeleteHighlight == null
          ? null
          : (id) async {
              final annotations = await onDeleteHighlight(id);
              bookmarks = List.of(annotations.bookmarks);
              highlights = List.of(annotations.highlights);
              return annotations;
            },
      onExportAnnotations: onExportAnnotations,
    );
    if (result == null || !context.mounted) return;
    if (result.action == ReflowTextReaderAction.selectChapter &&
        result.chapterIndex != null &&
        result.chapterIndex! >= 0 &&
        result.chapterIndex! < chapters.length) {
      chapterIndex = result.chapterIndex!;
      chapterPosition = result.targetPosition;
      continue;
    }
    if (result.action == ReflowTextReaderAction.nextChapter &&
        chapterIndex + 1 < chapters.length) {
      chapterIndex++;
      chapterPosition = null;
      continue;
    }
    if (result.action == ReflowTextReaderAction.previousChapter &&
        chapterIndex > 0) {
      chapterIndex--;
      chapterPosition = MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 1e18,
        fileId: fileId,
        chapterId: chapters[chapterIndex].id,
      );
      continue;
    }
    return;
  }
}
