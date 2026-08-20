import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/reader_progress_conflict.dart';
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
}
