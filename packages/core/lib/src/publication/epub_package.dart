import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:epubx_kuebiko/epubx_kuebiko.dart' as epub;
import 'package:path/path.dart' as p;

import 'publication_source.dart';

final class EpubPackageLimits {
  const EpubPackageLimits({
    this.maxArchiveBytes = 256 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxEntryBytes = 64 * 1024 * 1024,
    this.maxTotalBytes = 512 * 1024 * 1024,
    this.maxCompressionRatio = 200,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;
  final int maxCompressionRatio;
}

final class EpubPublicationChapter {
  const EpubPublicationChapter({
    required this.id,
    required this.title,
    required this.href,
    required this.html,
    required this.depth,
  });

  final String id;
  final String title;
  final String href;
  final String html;
  final int depth;
}

final class EpubPublication {
  const EpubPublication({
    required this.title,
    required this.authors,
    required this.languages,
    required this.subjects,
    required this.publishers,
    required this.description,
    required this.coverBytes,
    required this.coverMimeType,
    required this.chapters,
  });

  final String title;
  final List<String> authors;
  final List<String> languages;
  final List<String> subjects;
  final List<String> publishers;
  final String? description;
  final Uint8List? coverBytes;
  final String? coverMimeType;
  final List<EpubPublicationChapter> chapters;
}

final class EpubPackageAdapter {
  const EpubPackageAdapter({this.limits = const EpubPackageLimits()});

  final EpubPackageLimits limits;

  Future<EpubPublication> openFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const EpubPackageException(
        'Die EPUB-Datei ist nicht mehr am gespeicherten Ort vorhanden.',
      );
    }
    return openSource(FilePublicationSource(path));
  }

  Future<EpubPublication> openSource(PublicationSource source) async {
    try {
      final bytes = await source.readAll(maxBytes: limits.maxArchiveBytes);
      return openBytes(bytes, sourceName: source.name);
    } on PublicationSourceTooLargeException {
      throw const EpubPackageException(
        'Die EPUB-Datei überschreitet die konfigurierte Größenbegrenzung.',
      );
    } on PublicationSourceReadException catch (error) {
      throw EpubPackageException(error.message);
    }
  }

  Future<EpubPublication> openBytes(
    Uint8List bytes, {
    String sourceName = 'publication.epub',
  }) async {
    _preflight(bytes);
    try {
      final book = await epub.EpubReader.readBook(bytes);
      final metadata = book.Schema?.Package?.Metadata;
      final chapters = _chapters(book);
      if (chapters.isEmpty) {
        throw const EpubPackageException(
          'Das EPUB enthält keine lesbaren Kapitel in Navigation oder Spine.',
        );
      }
      final cover = _cover(book);
      return EpubPublication(
        title: _value(book.Title) ?? p.basenameWithoutExtension(sourceName),
        authors: _values(book.AuthorList),
        languages: _values(metadata?.Languages),
        subjects: _values(metadata?.Subjects),
        publishers: _values(metadata?.Publishers),
        description: _value(metadata?.Description),
        coverBytes: cover?.bytes,
        coverMimeType: cover?.mimeType,
        chapters: List.unmodifiable(chapters),
      );
    } on EpubPackageException {
      rethrow;
    } catch (_) {
      throw const EpubPackageException(
        'Das EPUB-Paket ist beschädigt oder verwendet eine noch nicht unterstützte Struktur.',
      );
    }
  }

  void _preflight(Uint8List bytes) {
    if (bytes.length > limits.maxArchiveBytes) {
      throw const EpubPackageException(
        'Die EPUB-Datei überschreitet die konfigurierte Größenbegrenzung.',
      );
    }
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const EpubPackageException(
        'Die EPUB-Datei ist kein gültiges ZIP-Paket.',
      );
    }
    try {
      if (archive.length > limits.maxEntries) {
        throw const EpubPackageException(
          'Das EPUB-Paket enthält zu viele Einträge.',
        );
      }
      var totalBytes = 0;
      var hasContainer = false;
      for (final entry in archive) {
        final canonical = _canonicalPath(entry.name);
        if (entry.isSymbolicLink) {
          throw const EpubPackageException(
            'EPUB-Pakete mit symbolischen Verknüpfungen werden nicht geöffnet.',
          );
        }
        if (canonical.toLowerCase() == 'meta-inf/container.xml') {
          hasContainer = true;
        }
        if (!entry.isFile) continue;
        if (entry.size > limits.maxEntryBytes) {
          throw EpubPackageException(
            'Der EPUB-Eintrag „${p.posix.basename(canonical)}“ ist zu groß.',
          );
        }
        totalBytes += entry.size;
        if (totalBytes > limits.maxTotalBytes) {
          throw const EpubPackageException(
            'Der entpackte Gesamtinhalt des EPUB-Pakets ist zu groß.',
          );
        }
        final compressedBytes = entry.rawContent?.length ?? 0;
        if (compressedBytes > 0 &&
            entry.size > 1024 * 1024 &&
            entry.size / compressedBytes > limits.maxCompressionRatio) {
          throw EpubPackageException(
            'Der EPUB-Eintrag „${p.posix.basename(canonical)}“ ist ungewöhnlich stark komprimiert.',
          );
        }
      }
      if (!hasContainer) {
        throw const EpubPackageException(
          'Dem EPUB-Paket fehlt META-INF/container.xml.',
        );
      }
    } finally {
      archive.clearSync();
    }
  }

  List<EpubPublicationChapter> _chapters(epub.EpubBook book) {
    final result = <EpubPublicationChapter>[];
    final occurrences = <String, int>{};
    void flatten(List<epub.EpubChapter> chapters, int depth) {
      for (final chapter in chapters) {
        final html = chapter.HtmlContent?.trim() ?? '';
        final href = _normalizedHref(chapter.ContentFileName);
        if (html.isNotEmpty) {
          _addChapter(
            result,
            occurrences,
            title: _value(chapter.Title) ?? _titleFromHref(href, result.length),
            href: href,
            anchor: _value(chapter.Anchor),
            html: html,
            depth: depth,
          );
        }
        flatten(chapter.SubChapters ?? const [], depth + 1);
      }
    }

    flatten(book.Chapters ?? const [], 0);
    if (result.isNotEmpty) return result;

    final htmlFiles = book.Content?.Html ?? const {};
    final manifest = book.Schema?.Package?.Manifest?.Items ?? const [];
    final manifestById = {for (final item in manifest) ?_value(item.Id): item};
    final spine = book.Schema?.Package?.Spine?.Items ?? const [];
    for (final item in spine) {
      if (item.IsLinear == false) continue;
      final manifestItem = manifestById[_value(item.IdRef)];
      final href = _normalizedHref(manifestItem?.Href);
      final content = _resolveHtml(htmlFiles, href);
      if (content == null || content.trim().isEmpty) continue;
      _addChapter(
        result,
        occurrences,
        title: _titleFromHtml(content) ?? _titleFromHref(href, result.length),
        href: href,
        html: content,
        depth: 0,
      );
    }
    return result;
  }

  static void _addChapter(
    List<EpubPublicationChapter> target,
    Map<String, int> occurrences, {
    required String title,
    required String href,
    required String html,
    required int depth,
    String? anchor,
  }) {
    final base = href.isEmpty ? 'chapter-${target.length + 1}' : href;
    final anchored = anchor == null ? base : '$base#$anchor';
    final occurrence = occurrences.update(
      anchored,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    target.add(
      EpubPublicationChapter(
        id: occurrence == 1 ? anchored : '$anchored@$occurrence',
        title: title,
        href: href,
        html: html,
        depth: depth,
      ),
    );
  }

  static String? _resolveHtml(
    Map<String, epub.EpubTextContentFile> files,
    String href,
  ) {
    if (href.isEmpty) return null;
    final direct = files[href]?.Content;
    if (direct != null) return direct;
    final normalizedMatches = files.entries
        .where((entry) => _normalizedHref(entry.key) == href)
        .toList(growable: false);
    if (normalizedMatches.length == 1) {
      return normalizedMatches.single.value.Content;
    }
    final basename = p.posix.basename(href);
    final basenameMatches = files.entries
        .where(
          (entry) => p.posix.basename(_normalizedHref(entry.key)) == basename,
        )
        .toList(growable: false);
    return basenameMatches.length == 1
        ? basenameMatches.single.value.Content
        : null;
  }

  static ({Uint8List bytes, String? mimeType})? _cover(epub.EpubBook book) {
    final images = book.Content?.Images ?? const {};
    final candidates = images.entries
        .where(
          (entry) =>
              entry.key.toLowerCase().contains('cover') ||
              (entry.value.FileName?.toLowerCase().contains('cover') ?? false),
        )
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    final value = candidates.first.value;
    final content = value.Content;
    if (content == null || content.isEmpty) return null;
    return (
      bytes: Uint8List.fromList(content),
      mimeType: _value(value.ContentMimeType),
    );
  }

  static String _canonicalPath(String value) {
    final normalized = value
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.contains('\u0000')) {
      throw const EpubPackageException(
        'Das EPUB-Paket enthält einen unsicheren Pfad.',
      );
    }
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const EpubPackageException(
        'Das EPUB-Paket enthält einen unsicheren Pfad.',
      );
    }
    return p.posix.joinAll(parts);
  }

  static String _normalizedHref(String? value) {
    final withoutFragment = (value ?? '')
        .split('#')
        .first
        .replaceAll('\\', '/');
    if (withoutFragment.isEmpty) return '';
    final decoded = Uri.decodeComponent(withoutFragment);
    final normalized = p.posix.normalize(decoded);
    return normalized == '.' ? '' : normalized.replaceFirst(RegExp(r'^/+'), '');
  }

  static String _titleFromHref(String href, int index) {
    if (href.isEmpty) return 'Kapitel ${index + 1}';
    final title = p
        .basenameWithoutExtension(href)
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .trim();
    return title.isEmpty ? 'Kapitel ${index + 1}' : title;
  }

  static String? _titleFromHtml(String html) {
    final match = RegExp(
      r'<title\b[^>]*>(.*?)</title>',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(html);
    return _value(match?.group(1)?.replaceAll(RegExp(r'<[^>]+>'), ' '));
  }

  static List<String> _values(Iterable<String?>? values) => List.unmodifiable(
    (values ?? const <String?>[]).map(_value).whereType<String>().toSet(),
  );

  static String? _value(String? value) {
    final normalized = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

final class EpubPackageException implements Exception {
  const EpubPackageException(this.message);

  final String message;

  @override
  String toString() => message;
}
