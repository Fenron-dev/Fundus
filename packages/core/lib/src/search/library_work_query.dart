import '../database/fundus_database.dart';

enum LibraryWorkSort {
  relevance,
  recentlyAdded,
  recentlyListened,
  title,
  author,
  series,
  progress,
  duration,
}

enum LibraryProgressFilter { any, notStarted, inProgress, finished }

final class LibraryWorkQuery {
  const LibraryWorkQuery({
    this.text = '',
    this.kinds = const {},
    this.sort = LibraryWorkSort.relevance,
    this.progress = LibraryProgressFilter.any,
    this.offlineOnly = false,
    this.languages = const {},
    this.authors = const {},
    this.narrators = const {},
    this.series = const {},
    this.tags = const {},
  });

  final String text;
  final Set<String> kinds;
  final LibraryWorkSort sort;
  final LibraryProgressFilter progress;
  final bool offlineOnly;
  final Set<String> languages;
  final Set<String> authors;
  final Set<String> narrators;
  final Set<String> series;
  final Set<String> tags;

  LibraryWorkQuery copyWith({
    String? text,
    Set<String>? kinds,
    LibraryWorkSort? sort,
    LibraryProgressFilter? progress,
    bool? offlineOnly,
    Set<String>? languages,
    Set<String>? authors,
    Set<String>? narrators,
    Set<String>? series,
    Set<String>? tags,
  }) => LibraryWorkQuery(
    text: text ?? this.text,
    kinds: kinds ?? this.kinds,
    sort: sort ?? this.sort,
    progress: progress ?? this.progress,
    offlineOnly: offlineOnly ?? this.offlineOnly,
    languages: languages ?? this.languages,
    authors: authors ?? this.authors,
    narrators: narrators ?? this.narrators,
    series: series ?? this.series,
    tags: tags ?? this.tags,
  );

  bool get hasFilters =>
      kinds.isNotEmpty ||
      progress != LibraryProgressFilter.any ||
      offlineOnly ||
      languages.isNotEmpty ||
      authors.isNotEmpty ||
      narrators.isNotEmpty ||
      series.isNotEmpty ||
      tags.isNotEmpty;

  Map<String, Object?> toJson() => {
    'text': text,
    'kinds': kinds.toList()..sort(),
    'sort': sort.name,
    'progress': progress.name,
    'offline_only': offlineOnly,
    'languages': languages.toList()..sort(),
    'authors': authors.toList()..sort(),
    'narrators': narrators.toList()..sort(),
    'series': series.toList()..sort(),
    'tags': tags.toList()..sort(),
  };

  static LibraryWorkQuery fromJson(Object? value) {
    if (value is! Map) return const LibraryWorkQuery();
    T enumValue<T extends Enum>(Iterable<T> values, Object? name, T fallback) {
      for (final value in values) {
        if (value.name == name) return value;
      }
      return fallback;
    }

    Set<String> strings(Object? raw) =>
        raw is List ? raw.whereType<String>().toSet() : const <String>{};
    return LibraryWorkQuery(
      text: value['text'] is String ? value['text'] as String : '',
      kinds: strings(value['kinds']),
      sort: enumValue(
        LibraryWorkSort.values,
        value['sort'],
        LibraryWorkSort.relevance,
      ),
      progress: enumValue(
        LibraryProgressFilter.values,
        value['progress'],
        LibraryProgressFilter.any,
      ),
      offlineOnly: value['offline_only'] == true,
      languages: strings(value['languages']),
      authors: strings(value['authors']),
      narrators: strings(value['narrators']),
      series: strings(value['series']),
      tags: strings(value['tags']),
    );
  }
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
      if (!_matchesFilters(work, query)) continue;
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

  static bool _matchesFilters(LibraryWorkSummary work, LibraryWorkQuery query) {
    if (query.offlineOnly && !work.offline) return false;
    final started = (work.progressPosition ?? Duration.zero) > Duration.zero;
    switch (query.progress) {
      case LibraryProgressFilter.any:
        break;
      case LibraryProgressFilter.notStarted:
        if (started || work.progressFinished) return false;
      case LibraryProgressFilter.inProgress:
        if (!started || work.progressFinished) return false;
      case LibraryProgressFilter.finished:
        if (!work.progressFinished) return false;
    }
    bool intersects(Set<String> selected, Iterable<String> values) {
      if (selected.isEmpty) return true;
      final normalized = values.map(_normalize).toSet();
      return selected.any((value) => normalized.contains(_normalize(value)));
    }

    if (!intersects(query.languages, [
      if (work.language != null) work.language!,
    ])) {
      return false;
    }
    if (!intersects(
      query.authors,
      work.authors.isEmpty ? [work.author] : work.authors,
    )) {
      return false;
    }
    if (!intersects(query.narrators, work.narrators)) return false;
    if (!intersects(query.series, [if (work.series != null) work.series!])) {
      return false;
    }
    if (query.tags.isNotEmpty) {
      final tags = work.tags.map(_normalize).toSet();
      if (!query.tags.every((tag) => tags.contains(_normalize(tag)))) {
        return false;
      }
    }
    return true;
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
      case LibraryWorkSort.recentlyListened:
        result =
            (right.lastListenedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                .compareTo(
                  left.lastListenedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
                );
        break;
      case LibraryWorkSort.progress:
        result = _progress(right).compareTo(_progress(left));
        break;
      case LibraryWorkSort.duration:
        result = (right.progressDuration ?? Duration.zero).compareTo(
          left.progressDuration ?? Duration.zero,
        );
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

  static double _progress(LibraryWorkSummary work) {
    if (work.progressFinished) return 1;
    final position = work.progressPosition?.inMilliseconds ?? 0;
    final duration = work.progressDuration?.inMilliseconds ?? 0;
    return duration <= 0 ? 0 : (position / duration).clamp(0, 1);
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
