import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  final works = [
    LibraryWorkSummary(
      id: '1',
      kind: 'audiobook',
      title: 'Winnetou I',
      author: 'Karl May',
      series: 'Winnetou',
      seriesSequence: 1,
      fileCount: 2,
      addedAt: DateTime(2026, 1, 1),
    ),
    LibraryWorkSummary(
      id: '2',
      kind: 'ebook',
      title: 'Der Ölprinz',
      author: 'Karl May',
      fileCount: 1,
      addedAt: DateTime(2026, 2, 1),
    ),
  ];

  test('finds misspelled titles using fuzzy matching', () {
    final result = LibraryWorkSearch.apply(
      works,
      const LibraryWorkQuery(text: 'Winetu'),
    );

    expect(result.map((work) => work.id), ['1']);
  });

  test('combines text and media kind filters', () {
    final result = LibraryWorkSearch.apply(
      works,
      const LibraryWorkQuery(text: 'Karl', kinds: {'ebook'}),
    );

    expect(result.map((work) => work.id), ['2']);
  });

  test('sorts recently added works descending', () {
    final result = LibraryWorkSearch.apply(
      works,
      const LibraryWorkQuery(sort: LibraryWorkSort.recentlyAdded),
    );

    expect(result.map((work) => work.id), ['2', '1']);
  });

  test('matches existing tags despite small typing mistakes', () {
    expect(LibraryFuzzySearch.matches('Abenteuer', 'Abentuer'), isTrue);
    expect(LibraryFuzzySearch.matches('Science Fiction', 'Scince'), isTrue);
    expect(LibraryFuzzySearch.matches('Romantik', 'Krimi'), isFalse);
  });
}
