import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

final class LibraryConfiguration {
  LibraryConfiguration({Map<String, Iterable<String>>? mediaRoots})
    : mediaRoots = Map<String, List<String>>.unmodifiable({
        for (final entry in (mediaRoots ?? defaults).entries)
          entry.key: List<String>.unmodifiable(
            entry.value
                .map((value) => _normalizeRoot(value))
                .where((value) => value.isNotEmpty)
                .toSet(),
          ),
      });

  static const formatVersion = 1;

  static const Map<String, List<String>> defaults = {
    'audiobook': ['Audiobooks', 'Hörbücher'],
    'movie': ['Movies', 'Filme'],
    'tv': ['TV Shows', 'Serien'],
    'book': ['Books', 'Bücher'],
    'webnovel': ['Webnovels', 'Web Novels'],
    'manga': ['Manga', 'Comics'],
    'music': ['Music', 'Musik'],
    'podcast': ['Podcasts'],
    'image': ['Pictures', 'Bilder', 'Fotos'],
    'document': ['Documents', 'Dokumente'],
    'ttrpg_product': ['TTRPG'],
    'archive': ['Archives', 'Backups'],
  };

  final Map<String, List<String>> mediaRoots;

  List<String> rootsFor(String kind) => mediaRoots[kind] ?? const [];

  static Future<LibraryConfiguration> readOrDefault(File file) async {
    if (!await file.exists()) return LibraryConfiguration();
    final value = loadYaml(await file.readAsString());
    if (value is! Map) {
      throw const FormatException('Ungültige Fundus-Bibliothekskonfiguration.');
    }
    final roots = value['media_roots'];
    if (roots == null) return LibraryConfiguration();
    if (roots is! Map) {
      throw const FormatException('media_roots muss eine Zuordnung sein.');
    }
    final parsed = <String, Iterable<String>>{};
    for (final entry in roots.entries) {
      if (entry.key is! String || entry.value is! List) {
        throw const FormatException('Ungültiger Eintrag unter media_roots.');
      }
      parsed[entry.key as String] = (entry.value as List).map((value) {
        if (value is! String) {
          throw const FormatException('Medienbereichspfade müssen Text sein.');
        }
        return value;
      });
    }
    return LibraryConfiguration(mediaRoots: {...defaults, ...parsed});
  }

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({'format_version': formatVersion, 'media_roots': mediaRoots})}\n',
      flush: true,
    );
  }

  static String _normalizeRoot(String value) => value
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '.')
      .join('/');
}
