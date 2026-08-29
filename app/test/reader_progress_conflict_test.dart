import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/reader_progress_conflict.dart';
import 'package:fundus/library/work_content_list.dart';
import 'package:fundus/server/remote_servers_view.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  MediaPosition position({
    required String fileId,
    required double page,
    double offset = .2,
  }) => MediaPosition(
    kind: MediaPositionKind.imageIndex,
    numericValue: page,
    total: 20,
    fileId: fileId,
    chapterId: 'Kapitel 1',
    scrollOffset: offset,
    label: 'Seite ${page.round()}',
  );

  test(
    'reader conflicts compare chapter page and meaningful scroll offset',
    () {
      final current = position(fileId: 'chapter-1', page: 4);
      expect(
        readerPositionsDiffer(
          current,
          position(fileId: 'chapter-1', page: 4, offset: .23),
        ),
        isFalse,
      );
      expect(
        readerPositionsDiffer(current, position(fileId: 'chapter-1', page: 5)),
        isTrue,
      );
      expect(
        readerPositionsDiffer(current, position(fileId: 'chapter-2', page: 4)),
        isTrue,
      );
    },
  );

  test('a synchronized device cache still offers a newer server position', () {
    expect(
      shouldResolveReaderProgressConflict(
        localPendingSync: false,
        devicePosition: position(fileId: 'chapter-1', page: 4),
        serverPosition: position(fileId: 'chapter-1', page: 12),
      ),
      isTrue,
    );
  });

  test('an unsynchronized offline change remains a real conflict', () {
    expect(
      shouldResolveReaderProgressConflict(
        localPendingSync: true,
        devicePosition: position(fileId: 'chapter-1', page: 4),
        serverPosition: position(fileId: 'chapter-1', page: 12),
      ),
      isTrue,
    );
  });

  testWidgets('reader conflict lets the user select the server position', (
    tester,
  ) async {
    ReaderProgressConflictChoice? choice;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              choice = await resolveReaderProgressConflict(
                context,
                devicePosition: position(fileId: 'a', page: 3),
                serverPosition: position(fileId: 'a', page: 8),
                deviceName: 'Handy',
                serverDeviceName: 'MacBook',
                askBeforeJumping: true,
              );
            },
            child: const Text('Prüfen'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Prüfen'));
    await tester.pumpAndSettle();
    expect(find.text('Abweichender Lesestand gefunden'), findsOneWidget);
    expect(find.text('Seite 3'), findsOneWidget);
    expect(find.text('Seite 8'), findsOneWidget);
    await tester.tap(find.text('Serverstand übernehmen'));
    await tester.pumpAndSettle();
    expect(choice, ReaderProgressConflictChoice.useServer);
  });

  testWidgets('reader history exposes device time position and jump action', (
    tester,
  ) async {
    ReaderProgressRevisionView? restored;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showReaderProgressHistory(
              context,
              loadHistory: () async => [
                ReaderProgressRevisionView(
                  revision: 8,
                  position: const MediaPosition(
                    kind: MediaPositionKind.imageIndex,
                    numericValue: 11,
                    total: 15,
                    fileId: 'chapter-2',
                    scrollOffset: .4,
                    label: 'Kapitel 2 · Seite 11',
                  ),
                  deviceId: 'tablet-1',
                  deviceName: 'Samsung Tablet',
                  createdAt: DateTime(2026, 8, 29, 9, 42),
                  fileTitle: 'Kapitel 0002.cbz',
                ),
              ],
              restoreRevision: (revision) async => restored = revision,
            ),
            child: const Text('Verlauf öffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Verlauf öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Gerätestände'), findsOneWidget);
    expect(
      find.text('Kapitel 2 · Seite 11 · 40 % innerhalb der Seite'),
      findsOneWidget,
    );
    expect(
      find.text('Samsung Tablet · Kapitel 0002.cbz · 29.08.2026, 09:42 Uhr'),
      findsOneWidget,
    );
    await tester.tap(find.text('Dorthin springen'));
    await tester.pumpAndSettle();
    expect(restored?.revision, 8);
    expect(find.text('Gerätestände'), findsNothing);
  });

  testWidgets('reader history hides duplicate positions from one device', (
    tester,
  ) async {
    const position = MediaPosition(
      kind: MediaPositionKind.imageIndex,
      numericValue: 11,
      total: 15,
      fileId: 'chapter-2',
      scrollOffset: .4,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showReaderProgressHistory(
              context,
              loadHistory: () async => [
                ReaderProgressRevisionView(
                  revision: 9,
                  position: position,
                  deviceId: 'tablet-1',
                  deviceName: 'Samsung Tablet',
                  createdAt: DateTime(2026, 8, 29, 9, 43),
                  fileTitle: 'Kapitel 0002.cbz',
                ),
                ReaderProgressRevisionView(
                  revision: 8,
                  position: position,
                  deviceId: 'tablet-1',
                  deviceName: 'Samsung Tablet',
                  createdAt: DateTime(2026, 8, 29, 9, 42),
                  fileTitle: 'Kapitel 0002.cbz',
                ),
              ],
              restoreRevision: (_) async {},
            ),
            child: const Text('Verlauf öffnen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Verlauf öffnen'));
    await tester.pumpAndSettle();
    expect(find.text('Dorthin springen'), findsOneWidget);
  });

  test('chapter read state follows the synchronized reader position', () {
    const current = MediaPosition(
      kind: MediaPositionKind.imageIndex,
      numericValue: 6,
      total: 15,
      fileId: 'chapter-3',
    );

    expect(
      documentChapterReadState(
        chapterIndex: 1,
        currentChapterIndex: 2,
        workFinished: false,
        currentPosition: current,
      ),
      DocumentChapterReadState.read,
    );
    expect(
      documentChapterReadState(
        chapterIndex: 2,
        currentChapterIndex: 2,
        workFinished: false,
        currentPosition: current,
      ),
      DocumentChapterReadState.current,
    );
    expect(
      documentChapterReadState(
        chapterIndex: 3,
        currentChapterIndex: 2,
        workFinished: false,
        currentPosition: current,
      ),
      DocumentChapterReadState.unread,
    );
  });

  test('chapter range accepts exact one-based bounds in either order', () {
    expect(chapterSelectionRange(total: 4000, start: 101, end: 200), {
      for (var index = 100; index < 200; index++) index,
    });
    expect(chapterSelectionRange(total: 10, start: 8, end: 5), {4, 5, 6, 7});
    expect(chapterSelectionRange(total: 10, start: -5, end: 99), {
      for (var index = 0; index < 10; index++) index,
    });
    expect(chapterSelectionRange(total: 0, start: 1, end: 1), isEmpty);
  });
}
