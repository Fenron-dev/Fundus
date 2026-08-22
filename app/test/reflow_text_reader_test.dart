import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus/library/epub_reader.dart';
import 'package:fundus/library/reflow_text_reader.dart';

void main() {
  testWidgets('mobile reader toggles its chrome with a center tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final document = ReflowDocument.parse(
      'Ein ausreichend langer Absatz für die mobile Leseansicht.',
      format: ReflowSourceFormat.plainText,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => unawaited(
              showReflowDocumentReader(
                context,
                document: document,
                title: 'Mobile EPUB',
              ),
            ),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Reader schließen'), findsOneWidget);

    final readerCenter = tester.getCenter(find.byType(SelectionArea));
    await tester.tapAt(readerCenter);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Reader schließen'), findsNothing);

    await tester.tapAt(readerCenter);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Reader schließen'), findsOneWidget);
    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pumpAndSettle();
  });

  test('internal reflow support is limited to safe text formats', () {
    expect(supportsInternalReflowTextReader('/books/chapter.HTML'), isTrue);
    expect(supportsInternalReflowTextReader('/books/chapter.md'), isTrue);
    expect(supportsInternalReflowTextReader('/books/book.epub'), isFalse);
    expect(supportsInternalReflowTextReader('/books/archive.zip'), isFalse);
  });

  test(
    'EPUB uses its package-aware reader instead of the plain text reader',
    () {
      expect(supportsInternalEpubReader('/books/Novel.EPUB'), isTrue);
      expect(supportsInternalEpubReader('/books/chapter.html'), isFalse);
      expect(supportsInternalEpubReader('/books/archive.zip'), isFalse);
    },
  );

  testWidgets('reader opens sanitized HTML at its semantic paragraph anchor', (
    tester,
  ) async {
    final directory = Directory.systemTemp.createTempSync(
      'fundus-reflow-reader-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final paragraphs = [
      for (var index = 0; index < 80; index++)
        '<p>Absatz $index mit ausreichend Text für die Leseansicht.</p>',
    ];
    final source = '<script>unsicher()</script>${paragraphs.join()}';
    final file = File('${directory.path}/chapter.html');
    file.writeAsStringSync(source);
    final document = ReflowDocument.parse(
      source,
      format: ReflowSourceFormat.html,
    );
    final initial = document.positionFor(
      paragraphIndex: 50,
      innerOffset: .2,
      fileId: 'chapter',
    );
    MediaPosition? reported;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => unawaited(
              showReflowTextReader(
                context,
                path: file.path,
                title: 'Kapitel 1',
                fileId: 'chapter',
                initialPosition: initial,
                onPositionChanged: (position) => reported = position,
              ),
            ),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );
    final openButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Öffnen'),
    );
    await tester.runAsync(() async {
      openButton.onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Kapitel 1'), findsOneWidget);
    expect(find.textContaining('unsicher'), findsNothing);
    expect(reported?.elementId, document.paragraphs[50].id);

    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('reader restores the precise semantic position after reopening', (
    tester,
  ) async {
    final document = ReflowDocument.parse(
      [
        for (var index = 0; index < 100; index++)
          'Absatz $index enthält ausreichend Text für einen stabilen Anker.',
      ].join('\n\n'),
      format: ReflowSourceFormat.plainText,
    );
    MediaPosition? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => unawaited(
              showReflowDocumentReader(
                context,
                document: document,
                title: 'Testnovel',
                initialPosition: saved,
                fileId: 'novel.epub',
                positionChapterId: 'chapter-1',
                onPositionChanged: (position) => saved = position,
              ),
            ),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -1900),
    );
    await tester.pump(const Duration(milliseconds: 400));
    final expected = saved;
    expect(expected?.elementId, isNotNull);
    expect(expected?.numericValue, greaterThan(0));
    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pumpAndSettle();

    saved = expected;
    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    final restored = saved;
    expect(restored?.elementId, expected?.elementId);
    expect(
      restored?.scrollOffset ?? 0,
      closeTo(expected?.scrollOffset ?? 0, .03),
    );
    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pumpAndSettle();
  });

  testWidgets('reader search jumps to the semantic text match', (tester) async {
    final document = ReflowDocument.parse(
      [
        for (var index = 0; index < 90; index++)
          index == 72
              ? 'Hier befindet sich das seltene Drachenamulett.'
              : 'Absatz $index enthält gewöhnlichen Beispieltext.',
      ].join('\n\n'),
      format: ReflowSourceFormat.plainText,
    );
    MediaPosition? reported;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => unawaited(
              showReflowDocumentReader(
                context,
                document: document,
                title: 'Suchtest',
                positionChapterId: 'chapter-search',
                onPositionChanged: (position) => reported = position,
              ),
            ),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Im Buch suchen'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Im Kapitel suchen'),
      'Drachenamulett',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final searchResult = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.maxLines == 3 &&
          (widget.data?.contains('seltene Drachenamulett') ?? false),
    );
    expect(searchResult, findsOneWidget);
    await tester.tap(searchResult);
    await tester.pumpAndSettle();

    expect(reported?.elementId, document.paragraphs[72].id);
    expect(reported?.chapterId, 'chapter-search');
    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pumpAndSettle();
  });

  testWidgets('reader creates and lists semantic text bookmarks', (
    tester,
  ) async {
    final document = ReflowDocument.parse(
      'Erster Absatz.\n\nZweiter Absatz.',
      format: ReflowSourceFormat.plainText,
    );
    MediaPosition? bookmarkedAt;
    var annotations = const WorkAnnotations();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => unawaited(
              showReflowDocumentReader(
                context,
                document: document,
                title: 'Lesezeichentest',
                fileId: 'novel.epub',
                positionChapterId: 'chapter-1',
                chapterIds: const ['chapter-1'],
                onAddBookmark: (position, label) async {
                  bookmarkedAt = position;
                  annotations = WorkAnnotations(
                    bookmarks: [
                      LibraryBookmark(
                        id: 'bookmark-1',
                        workId: 'work-1',
                        fileId: 'novel.epub',
                        mediaPosition: position,
                        label: label,
                        createdAt: DateTime(2026),
                      ),
                    ],
                  );
                  return annotations;
                },
              ),
            ),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Lesezeichen hinzufügen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Meine Stelle');
    await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
    await tester.pumpAndSettle();

    expect(bookmarkedAt?.chapterId, 'chapter-1');
    expect(bookmarkedAt?.elementId, document.paragraphs.first.id);
    await tester.tap(find.byTooltip('Lesezeichen und Markierungen'));
    await tester.pumpAndSettle();
    expect(find.text('Meine Stelle'), findsOneWidget);
    await tester.tap(find.text('Meine Stelle'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pumpAndSettle();
  });

  testWidgets('reader renders and opens stored text highlights', (
    tester,
  ) async {
    final document = ReflowDocument.parse(
      'Ein wichtiges Zitat bleibt sichtbar.',
      format: ReflowSourceFormat.plainText,
    );
    final position = document.positionFor(
      paragraphIndex: 0,
      innerOffset: 4 / document.paragraphs.first.text.length,
      fileId: 'novel.epub',
      chapterId: 'chapter-1',
    );
    final highlight = LibraryHighlight(
      id: 'highlight-1',
      workId: 'work-1',
      fileId: 'novel.epub',
      mediaPosition: position,
      quote: 'wichtiges Zitat',
      color: '#90CAF9',
      note: 'Merken',
      createdAt: DateTime(2026),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => unawaited(
              showReflowDocumentReader(
                context,
                document: document,
                title: 'Markierungstest',
                fileId: 'novel.epub',
                positionChapterId: 'chapter-1',
                chapterIds: const ['chapter-1'],
                initialHighlights: [highlight],
              ),
            ),
            child: const Text('Öffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Öffnen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('wichtiges Zitat'), findsOneWidget);
    await tester.tap(find.byTooltip('Lesezeichen und Markierungen'));
    await tester.pumpAndSettle();
    expect(find.text('Merken'), findsOneWidget);
    expect(find.textContaining('wichtiges Zitat'), findsWidgets);
    await tester.tap(find.textContaining('wichtiges Zitat').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Reader schließen'));
    await tester.pumpAndSettle();
  });
}
