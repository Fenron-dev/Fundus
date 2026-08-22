import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus/library/epub_reader.dart';
import 'package:fundus/library/reflow_text_reader.dart';

void main() {
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
}
