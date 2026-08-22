import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('HTML webnovels become safe readable paragraphs', () {
    final document = ReflowDocument.parse('''
      <html><head><style>hidden</style></head><body>
      <h1>Kapitel 1</h1>
      <p>Hallo &amp; willkommen&nbsp;hier.</p>
      <script>doNotRun()</script>
      <p>Zweite Zeile &#x2013; Ende.</p>
      </body></html>
      ''', format: ReflowSourceFormat.html);

    expect(document.paragraphs.map((item) => item.text), [
      'Kapitel 1',
      'Hallo & willkommen hier.',
      'Zweite Zeile – Ende.',
    ]);
    expect(
      document.paragraphs.map((item) => item.text).join(' '),
      isNot(contains('doNotRun')),
    );
  });

  test('semantic paragraph anchor survives preceding content changes', () {
    final original = ReflowDocument.parse(
      'Erster Absatz.\n\nDer wichtige Absatz.\n\nSchluss.',
      format: ReflowSourceFormat.plainText,
    );
    final position = original.positionFor(
      paragraphIndex: 1,
      innerOffset: .4,
      fileId: 'chapter-1',
    );
    final updated = ReflowDocument.parse(
      'Neue Einleitung.\n\nErster Absatz.\n\nDer wichtige Absatz.\n\nSchluss.',
      format: ReflowSourceFormat.plainText,
    );

    final resolved = updated.resolve(position);
    expect(resolved.paragraphIndex, 2);
    expect(resolved.innerOffset, closeTo(.4, .001));
  });

  test('character position is a fallback when an anchor disappeared', () {
    final document = ReflowDocument.parse(
      'Kurz.\n\nEin deutlich längerer zweiter Absatz.',
      format: ReflowSourceFormat.markdown,
    );
    final resolved = document.resolve(
      const MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 12,
        elementId: 'missing',
      ),
    );

    expect(resolved.paragraphIndex, 1);
  });

  test('search returns stable semantic offsets and useful snippets', () {
    final document = ReflowDocument.parse(
      'Einleitung.\n\nDas Fundstück liegt hier. Ein zweites FUNDSTÜCK folgt.',
      format: ReflowSourceFormat.plainText,
    );

    final matches = document.search('Fundstück');

    expect(matches, hasLength(2));
    expect(matches.first.paragraphIndex, 1);
    expect(matches.first.innerOffset, closeTo(4 / 58, .01));
    expect(matches.first.snippet, contains('Fundstück liegt hier'));
    final position = document.positionFor(
      paragraphIndex: matches.first.paragraphIndex,
      innerOffset: matches.first.innerOffset,
      chapterId: 'chapter-1',
    );
    expect(position.elementId, document.paragraphs[1].id);
    expect(position.chapterId, 'chapter-1');
  });
}
