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
    final document = ReflowDocument.parse(
      chapter.html,
      format: ReflowSourceFormat.html,
    );
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
    );
    if (result == null || !context.mounted) return;
    if (result.action == ReflowTextReaderAction.selectChapter &&
        result.chapterIndex != null &&
        result.chapterIndex! >= 0 &&
        result.chapterIndex! < chapters.length) {
      chapterIndex = result.chapterIndex!;
      chapterPosition = null;
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
