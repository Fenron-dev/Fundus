import 'package:fundus_core/fundus_core.dart';

/// Evaluates the portable rule format used by smart collections.
///
/// Rules intentionally use only provider-neutral metadata so a collection can
/// be evaluated for local, remote and offline catalog entries alike.
bool matchesCollectionRules(
  LibraryWorkSummary work,
  Map<String, Object?>? rules,
) {
  if (rules == null || rules.isEmpty) return true;

  String normalize(String value) => value
      .toLowerCase()
      .replaceAll('ä', 'ae')
      .replaceAll('ö', 'oe')
      .replaceAll('ü', 'ue')
      .replaceAll('ß', 'ss')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();

  bool matchesAny(Object? raw, Iterable<String> values) {
    if (raw is! List || raw.isEmpty) return true;
    final available = values.map(normalize).toSet();
    return raw.whereType<String>().any(
      (value) => available.contains(normalize(value)),
    );
  }

  bool matchesAll(Object? raw, Iterable<String> values) {
    if (raw is! List || raw.isEmpty) return true;
    final available = values.map(normalize).toSet();
    return raw.whereType<String>().every(
      (value) => available.contains(normalize(value)),
    );
  }

  if (!matchesAny(rules['kinds'], [work.kind])) return false;
  if (!matchesAny(rules['content_styles'], [
    if (work.contentStyle != null) work.contentStyle!,
  ])) {
    return false;
  }
  if (!matchesAny(rules['sensitivities'], [
    if (work.contentSensitivity != null) work.contentSensitivity!,
  ])) {
    return false;
  }
  if (!matchesAny(rules['languages'], [
    if (work.language != null) work.language!,
  ])) {
    return false;
  }
  if (!matchesAny(
    rules['authors'],
    work.authors.isEmpty ? [work.author] : work.authors,
  )) {
    return false;
  }
  if (!matchesAny(rules['narrators'], work.narrators)) return false;
  if (!matchesAny(rules['series'], [if (work.series != null) work.series!])) {
    return false;
  }
  if (!matchesAll(rules['tags_all'], work.tags)) return false;
  if (!matchesAny(rules['tags_any'], work.tags)) return false;
  if (!matchesAny(rules['genres'], work.genres)) return false;
  if (rules['offline_only'] == true && !work.offline) return false;

  final query = rules['text'];
  if (query is String && query.trim().isNotEmpty) {
    final haystack = normalize(
      [
        work.title,
        work.author,
        work.series ?? '',
        work.subtitle ?? '',
        work.description ?? '',
        ...work.narrators,
        ...work.genres,
        ...work.tags,
      ].join(' '),
    );
    final terms = normalize(query).split(' ').where((term) => term.isNotEmpty);
    if (!terms.every(haystack.contains)) return false;
  }
  return true;
}

/// Creates a portable smart-collection rule set from the current library
/// query and section. Empty criteria are omitted to keep the sidecar compact.
Map<String, Object?> collectionRulesFromQuery(
  LibraryWorkQuery query, {
  Set<String>? sectionKinds,
  String? contentStyle,
  String? sensitivity,
}) {
  final rules = <String, Object?>{};
  void addList(String key, Iterable<String> values) {
    final list =
        values.where((value) => value.trim().isNotEmpty).toSet().toList()
          ..sort();
    if (list.isNotEmpty) rules[key] = list;
  }

  addList('kinds', sectionKinds ?? query.kinds);
  if (contentStyle != null && contentStyle.trim().isNotEmpty) {
    rules['content_styles'] = [contentStyle.trim()];
  }
  if (sensitivity != null && sensitivity.trim().isNotEmpty) {
    rules['sensitivities'] = [sensitivity.trim()];
  }
  if (query.text.trim().isNotEmpty) rules['text'] = query.text.trim();
  addList('languages', query.languages);
  addList('authors', query.authors);
  addList('narrators', query.narrators);
  addList('series', query.series);
  addList('tags_all', query.tags);
  if (query.offlineOnly) rules['offline_only'] = true;
  return rules;
}
