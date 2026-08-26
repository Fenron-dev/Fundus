import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import 'zip_archive_browser.dart';

const _comicImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
};

abstract interface class ComicPageSource {
  String get name;

  PublicationSourceKind get kind;

  Future<List<ComicPage>> pages();

  Future<Map<String, String>> materialize(List<ComicPage> pages);

  Future<void> dispose();
}

final class ComicPage {
  const ComicPage({
    required this.id,
    required this.name,
    required this.size,
    this.mimeType,
    this.width,
    this.height,
  });

  final String id;
  final String name;
  final int size;
  final String? mimeType;
  final int? width;
  final int? height;
}

/// CBZ-backed source used for local libraries, durable offline downloads and
/// remote chapters that have been materialized in the bounded document cache.
final class ArchiveComicPageSource implements ComicPageSource {
  ArchiveComicPageSource(
    this.archivePath, {
    this.kind = PublicationSourceKind.local,
    String? name,
    this.service = const ZipArchiveService(),
  }) : _name = name;

  final String archivePath;
  @override
  final PublicationSourceKind kind;
  final String? _name;
  final ZipArchiveService service;
  final Map<String, ZipArchiveEntry> _archiveEntries = {};

  @override
  String get name => _name ?? p.basename(archivePath);

  @override
  Future<List<ComicPage>> pages() async {
    final entries = comicPageEntries(await service.inspect(archivePath));
    _archiveEntries
      ..clear()
      ..addEntries(entries.map((entry) => MapEntry(entry.path, entry)));
    return [
      for (final entry in entries)
        ComicPage(id: entry.path, name: entry.name, size: entry.size),
    ];
  }

  @override
  Future<Map<String, String>> materialize(List<ComicPage> pages) async {
    if (pages.isEmpty) return const {};
    if (pages.any((page) => !_archiveEntries.containsKey(page.id))) {
      await this.pages();
    }
    final entries = <ZipArchiveEntry>[];
    for (final page in pages) {
      final entry = _archiveEntries[page.id];
      if (entry == null || entry.size != page.size || entry.name != page.name) {
        throw const ZipArchiveException(
          'Die Comicseite ist nicht mehr Teil dieser Quelle.',
        );
      }
      entries.add(entry);
    }
    return service.extractToTemporaryFiles(archivePath, entries);
  }

  @override
  Future<void> dispose() async {}
}

List<ZipArchiveEntry> comicPageEntries(ZipArchiveSnapshot snapshot) {
  final pages = snapshot.entries
      .where(
        (entry) =>
            !entry.isDirectory &&
            _comicImageExtensions.contains(
              p.extension(entry.path).toLowerCase(),
            ),
      )
      .toList(growable: false);
  pages.sort((left, right) => _naturalCompare(left.path, right.path));
  return pages;
}

int _naturalCompare(String left, String right) {
  final leftParts = _naturalParts(left.toLowerCase());
  final rightParts = _naturalParts(right.toLowerCase());
  for (
    var index = 0;
    index < leftParts.length && index < rightParts.length;
    index++
  ) {
    final leftPart = leftParts[index];
    final rightPart = rightParts[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    final comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}

List<String> _naturalParts(String value) => RegExp(
  r'\d+|\D+',
).allMatches(value).map((match) => match.group(0)!).toList();
