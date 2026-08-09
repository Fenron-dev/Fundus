import '../database/fundus_database.dart';

enum LibraryWorkSort { relevance, recentlyAdded, title, author, series }

final class LibraryWorkQuery {
  const LibraryWorkQuery({
    this.text = '',
    this.kinds = const {},
    this.sort = LibraryWorkSort.relevance,
  });

  final String text;
  final Set<String> kinds;
  final LibraryWorkSort sort;

  LibraryWorkQuery copyWith({
    String? text,
    Set<String>? kinds,
    LibraryWorkSort? sort,
  }) => LibraryWorkQuery(
    text: text ?? this.text,
    kinds: kinds ?? this.kinds,
    sort: sort ?? this.sort,
  );
}

final class LibraryWorkSearch {
  const LibraryWorkSearch._();

  static List<LibraryWorkSummary> apply(
    Iterable<LibraryWorkSummary> works,
    LibraryWorkQuery query,
  ) {
    final needle = _normalize(query.text);
    final scored = <({LibraryWorkSummary work, double score})>[];
    for (final work in works) {
      if (query.kinds.isNotEmpty && !query.kinds.contains(work.kind)) continue;
      final score = needle.isEmpty ? 1.0 : _score(work, needle);
      if (score >= .58) scored.add((work: work, score: score));
    }
    scored.sort((left, right) {
      if (query.sort == LibraryWorkSort.relevance && needle.isNotEmpty) {
        final score = right.score.compareTo(left.score);
        if (score != 0) return score;
      }
      return _compare(left.work, right.work, query.sort);
    });
    return scored.map((entry) => entry.work).toList(growable: false);
  }

  static double _score(LibraryWorkSummary work, String needle) {
    return _scoreFields([
      work.title,
      work.author,
      work.series ?? '',
      work.subtitle ?? '',
      work.description ?? '',
      ...work.narrators,
      ...work.genres,
      if (work.seriesSequence case final sequence?)
        'Band ${sequence == sequence.roundToDouble() ? sequence.toInt() : sequence}',
    ], needle);
  }

  static double _scoreFields(Iterable<String> values, String needle) {
    final fields = values
        .map(_normalize)
        .where((field) => field.isNotEmpty)
        .toList(growable: false);
    final combined = fields.join(' ');
    if (combined == needle) return 1;
    if (combined.contains(needle)) return .96;

    final queryTerms = needle.split(' ');
    final candidateTerms = combined.split(' ');
    var total = 0.0;
    for (final queryTerm in queryTerms) {
      var best = 0.0;
      for (final candidate in candidateTerms) {
        if (candidate.startsWith(queryTerm) ||
            queryTerm.startsWith(candidate)) {
          best = best < .9 ? .9 : best;
          continue;
        }
        final longest = queryTerm.length > candidate.length
            ? queryTerm.length
            : candidate.length;
        if (longest == 0) continue;
        final similarity = 1 - _distance(queryTerm, candidate) / longest;
        if (similarity > best) best = similarity;
      }
      total += best;
    }
    return total / queryTerms.length;
  }

  static int _compare(
    LibraryWorkSummary left,
    LibraryWorkSummary right,
    LibraryWorkSort sort,
  ) {
    int result;
    switch (sort) {
      case LibraryWorkSort.recentlyAdded:
        result = right.addedAt.compareTo(left.addedAt);
        break;
      case LibraryWorkSort.author:
        result = _normalize(left.author).compareTo(_normalize(right.author));
        break;
      case LibraryWorkSort.series:
        result = _normalize(
          left.series ?? left.title,
        ).compareTo(_normalize(right.series ?? right.title));
        if (result == 0) {
          result = (left.seriesSequence ?? double.infinity).compareTo(
            right.seriesSequence ?? double.infinity,
          );
        }
        break;
      case LibraryWorkSort.relevance:
      case LibraryWorkSort.title:
        result = _normalize(left.title).compareTo(_normalize(right.title));
        break;
    }
    if (result != 0) return result;
    return _normalize(left.title).compareTo(_normalize(right.title));
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();

  static int _distance(String left, String right) {
    if (left == right) return 0;
    if (left.isEmpty) return right.length;
    if (right.isEmpty) return left.length;
    var previous = List<int>.generate(right.length + 1, (index) => index);
    for (var leftIndex = 0; leftIndex < left.length; leftIndex++) {
      final current = List<int>.filled(right.length + 1, 0);
      current[0] = leftIndex + 1;
      for (var rightIndex = 0; rightIndex < right.length; rightIndex++) {
        final substitution =
            previous[rightIndex] +
            (left.codeUnitAt(leftIndex) == right.codeUnitAt(rightIndex)
                ? 0
                : 1);
        final insertion = current[rightIndex] + 1;
        final deletion = previous[rightIndex + 1] + 1;
        current[rightIndex + 1] = [
          substitution,
          insertion,
          deletion,
        ].reduce((a, b) => a < b ? a : b);
      }
      previous = current;
    }
    return previous.last;
  }
}

final class LibraryFuzzySearch {
  const LibraryFuzzySearch._();

  static bool matches(
    String candidate,
    String query, {
    double threshold = .58,
  }) {
    final needle = LibraryWorkSearch._normalize(query);
    if (needle.isEmpty) return true;
    return LibraryWorkSearch._scoreFields([candidate], needle) >= threshold;
  }
}
