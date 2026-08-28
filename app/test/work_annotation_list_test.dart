import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/work_annotation_list.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  const position = MediaPosition(
    kind: MediaPositionKind.epubCfi,
    key: 'chapter-3#paragraph-12',
    chapterId: 'Kapitel 3',
    label: 'Absatz 12',
  );

  testWidgets('annotation list exposes bookmark and highlight jump targets', (
    tester,
  ) async {
    String? opened;
    final createdAt = DateTime.utc(2026, 8, 28, 12, 34);
    final bookmark = LibraryBookmark(
      id: 'bookmark-1',
      workId: 'work-1',
      mediaPosition: position,
      createdAt: createdAt,
      label: 'Wichtige Stelle',
    );
    final highlight = LibraryHighlight(
      id: 'highlight-1',
      workId: 'work-1',
      mediaPosition: position,
      quote: 'Ein markierter Satz',
      createdAt: createdAt,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkAnnotationList(
            bookmarks: [bookmark],
            highlights: [highlight],
            onOpenBookmark: (item) => opened = item.id,
            onOpenHighlight: (item) => opened = item.id,
          ),
        ),
      ),
    );

    expect(find.text('Wichtige Stelle'), findsOneWidget);
    expect(find.text('Ein markierter Satz'), findsOneWidget);
    expect(find.textContaining('Kapitel 3'), findsNWidgets(2));
    await tester.tap(find.text('Ein markierter Satz'));
    expect(opened, 'highlight-1');
  });

  testWidgets('note cards use a stable user-facing timestamp', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkNotesList(
            notes: [
              LibraryNote(
                id: 'note-1',
                markdown: '**Merken**',
                createdAt: DateTime(2026, 8, 28, 12, 34),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('28.08.2026 12:34'), findsOneWidget);
    expect(find.text('**Merken**'), findsOneWidget);
  });
}
