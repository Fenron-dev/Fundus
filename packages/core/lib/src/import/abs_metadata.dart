import 'dart:convert';
import 'dart:io';

final class AbsAudiobookMetadata {
  const AbsAudiobookMetadata({
    this.title,
    this.subtitle,
    this.author,
    this.authors = const [],
    this.narrators = const [],
    this.series,
    this.sequence,
    this.language,
    this.description,
    this.publisher,
    this.publishedYear,
    this.isbn,
    this.asin,
    this.tags = const [],
    this.genres = const [],
    this.explicit,
    this.abridged,
  });

  final String? title;
  final String? subtitle;
  final String? author;
  final List<String> authors;
  final List<String> narrators;
  final String? series;
  final double? sequence;
  final String? language;
  final String? description;
  final String? publisher;
  final int? publishedYear;
  final String? isbn;
  final String? asin;
  final List<String> tags;
  final List<String> genres;
  final bool? explicit;
  final bool? abridged;

  Map<String, Object?> toDatabaseMetadata() => {
    if (author != null) 'author': author,
    if (authors.isNotEmpty) 'authors': authors,
    if (subtitle != null) 'subtitle': subtitle,
    if (narrators.isNotEmpty) 'narrators': narrators,
    if (language != null) 'language': language,
    if (description != null) 'description': description,
    if (publisher != null) 'publisher': publisher,
    if (publishedYear != null) 'published_year': publishedYear,
    if (isbn != null) 'isbn': isbn,
    if (asin != null) 'asin': asin,
    if (genres.isNotEmpty) 'genres': genres,
    if (explicit != null) 'explicit': explicit,
    if (abridged != null) 'abridged': abridged,
  };
}

final class AbsMetadataReader {
  const AbsMetadataReader();

  static const _maximumBytes = 2 * 1024 * 1024;

  Future<AbsAudiobookMetadata?> read(File file) async {
    if (!await file.exists() || await file.length() > _maximumBytes) {
      return null;
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final authors = _strings(decoded['authors']);
    final seriesValues = _strings(decoded['series']);
    final parsedSeries = _parseSeries(seriesValues.firstOrNull);
    return AbsAudiobookMetadata(
      title: _string(decoded['title']),
      subtitle: _string(decoded['subtitle']),
      author: authors.isEmpty ? null : authors.join(', '),
      authors: authors,
      narrators: _strings(decoded['narrators']),
      series: parsedSeries.name,
      sequence: parsedSeries.sequence,
      language: _string(decoded['language']),
      description: _plainText(_string(decoded['description'])),
      publisher: _string(decoded['publisher']),
      publishedYear: _integer(decoded['publishedYear']),
      isbn: _string(decoded['isbn']),
      asin: _string(decoded['asin']),
      tags: _strings(decoded['tags']),
      genres: _strings(decoded['genres']),
      explicit: decoded['explicit'] is bool
          ? decoded['explicit'] as bool
          : null,
      abridged: decoded['abridged'] is bool
          ? decoded['abridged'] as bool
          : null,
    );
  }

  static ({String? name, double? sequence}) _parseSeries(String? value) {
    if (value == null) return (name: null, sequence: null);
    final match = RegExp(r'^(.*?)\s+#(\d+(?:[.,]\d+)?)$').firstMatch(value);
    if (match == null) return (name: value, sequence: null);
    return (
      name: _string(match.group(1)),
      sequence: double.tryParse(match.group(2)!.replaceAll(',', '.')),
    );
  }

  static String? _string(Object? value, {int maximumLength = 1000}) {
    if (value is! String) return null;
    final normalized = value.trim();
    if (normalized.isEmpty) return null;
    return normalized.length <= maximumLength
        ? normalized
        : normalized.substring(0, maximumLength);
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return value is String ? int.tryParse(value) : null;
  }

  static List<String> _strings(Object? value) {
    if (value is! List) return const [];
    return value
        .take(100)
        .map((item) => _string(item, maximumLength: 200))
        .whereType<String>()
        .toSet()
        .toList(growable: false);
  }

  static String? _plainText(String? html) {
    if (html == null) return null;
    var text = html
        .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(r'</\s*(p|div|li|h[1-6])\s*>', caseSensitive: false),
          '\n\n',
        )
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
      final code = int.tryParse(match.group(1)!);
      return code == null ? match.group(0)! : String.fromCharCode(code);
    });
    text = text
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (text.isEmpty) return null;
    return text.length <= 20000 ? text : text.substring(0, 20000);
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
