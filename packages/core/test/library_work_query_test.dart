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
      language: 'de',
      narrators: const ['Christian Brückner'],
      tags: const ['Abenteuer', 'Western'],
      progressPosition: const Duration(hours: 2),
      progressDuration: const Duration(hours: 10),
      lastListenedAt: DateTime(2026, 3, 1),
    ),
    LibraryWorkSummary(
      id: '2',
      kind: 'ebook',
      title: 'Der Ölprinz',
      author: 'Karl May',
      fileCount: 1,
      addedAt: DateTime(2026, 2, 1),
      language: 'en',
      tags: const ['Abenteuer'],
      progressFinished: true,
      progressPosition: const Duration(hours: 4),
      progressDuration: const Duration(hours: 4),
      lastListenedAt: DateTime(2026, 2, 1),
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

  test('filters series entries by volume number', () {
    final result = LibraryWorkSearch.apply(
      works,
      const LibraryWorkQuery(text: 'Band 1'),
    );

    expect(result.map((work) => work.id), ['1']);
  });

  test('combines progress, language, narrator, series and tags', () {
    final result = LibraryWorkSearch.apply(
      works,
      const LibraryWorkQuery(
        progress: LibraryProgressFilter.inProgress,
        languages: {'de'},
        narrators: {'Christian Brückner'},
        series: {'Winnetou'},
        tags: {'Abenteuer', 'Western'},
      ),
    );

    expect(result.map((work) => work.id), ['1']);
  });

  test('sorts by latest playback and progress', () {
    expect(
      LibraryWorkSearch.apply(
        works,
        const LibraryWorkQuery(sort: LibraryWorkSort.recentlyListened),
      ).map((work) => work.id),
      ['1', '2'],
    );
    expect(
      LibraryWorkSearch.apply(
        works,
        const LibraryWorkQuery(sort: LibraryWorkSort.progress),
      ).map((work) => work.id),
      ['2', '1'],
    );
  });

  test('query round-trips as a saved view', () {
    const query = LibraryWorkQuery(
      text: 'Karl',
      kinds: {'audiobook'},
      sort: LibraryWorkSort.duration,
      progress: LibraryProgressFilter.finished,
      offlineOnly: true,
      languages: {'de'},
      authors: {'Karl May'},
      narrators: {'Christian Brückner'},
      series: {'Winnetou'},
      tags: {'Abenteuer'},
    );

    final restored = LibraryWorkQuery.fromJson(query.toJson());
    expect(restored.text, query.text);
    expect(restored.kinds, query.kinds);
    expect(restored.sort, query.sort);
    expect(restored.progress, query.progress);
    expect(restored.offlineOnly, isTrue);
    expect(restored.languages, query.languages);
    expect(restored.authors, query.authors);
    expect(restored.narrators, query.narrators);
    expect(restored.series, query.series);
    expect(restored.tags, query.tags);
  });
}
