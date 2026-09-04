import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'fundus_library_catalog.dart';

/// Device-local, source-aware catalog mirror.
///
/// The mirror contains metadata only.  Media bytes stay in their source and
/// are opened through [FundusSourceGateway].  A source is replaced atomically
/// so a failed refresh can never leave a half-written catalog in the UI.
/// Keeping this store independent from a vault also makes network-mounted
/// libraries fast and safe: SQLite never needs to run over SMB/NFS.
final class FundusCatalogMirrorStore {
  const FundusCatalogMirrorStore({this.file});

  final File? file;

  Future<File> _resolvedFile() async {
    if (file != null) return file!;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'Fundus', 'catalog'));
    await directory.create(recursive: true);
    return File(p.join(directory.path, 'catalog.db'));
  }

  Future<List<FundusCatalogEntry>> load() async {
    final target = await _resolvedFile();
    if (!await target.exists()) return const [];
    Database? database;
    try {
      database = _open(target);
      final rows = database.select('''
        SELECT s.id AS source_id, s.kind AS source_kind,
               s.display_name, s.library_name, s.availability,
               w.work_id, w.payload_json
        FROM catalog_sources s
        JOIN catalog_works w ON w.source_id = s.id
        ORDER BY s.display_name COLLATE NOCASE, w.work_id
      ''');
      final entries = <FundusCatalogEntry>[];
      for (final row in rows) {
        final source = _sourceFromRow(row);
        if (source == null) continue;
        try {
          final value = jsonDecode(row['payload_json'] as String);
          final work = _workFromJson(value);
          if (work != null) {
            entries.add(FundusCatalogEntry(work: work, source: source));
          }
        } on FormatException {
          // A single corrupt metadata row must not hide every other source.
        }
      }
      return entries;
    } on SqliteException {
      return const [];
    } on FileSystemException {
      return const [];
    } finally {
      database?.close();
    }
  }

  /// Replaces one source and removes stale works from that source only.
  Future<void> replaceSource(
    String sourceId,
    Iterable<FundusCatalogEntry> entries, {
    FundusCatalogSource? source,
  }) async {
    final normalizedId = sourceId.trim();
    if (normalizedId.isEmpty) throw ArgumentError.value(sourceId, 'sourceId');
    // Offline copies deliberately keep the peer source identity.  A refresh
    // can therefore contain both the streamed row and its local copy.  Apply
    // the same source/work priority rules as the UI before writing the
    // `(source_id, work_id)` primary key.
    final values = FundusLibraryCatalog(entries).entries;
    final resolvedSource = source ?? values.firstOrNull?.source;
    if (resolvedSource == null || resolvedSource.id != normalizedId) {
      throw ArgumentError('Eine Quelle mit derselben ID ist erforderlich.');
    }
    for (final entry in values) {
      if (entry.source.id != normalizedId) {
        throw ArgumentError(
          'Alle Katalogeinträge müssen derselben Quelle angehören.',
        );
      }
    }
    final target = await _resolvedFile();
    await target.parent.create(recursive: true);
    Database? database;
    try {
      database = _open(target);
      database.execute('BEGIN IMMEDIATE');
      try {
        _upsertSource(database, resolvedSource);
        database.execute('DELETE FROM catalog_works WHERE source_id = ?', [
          normalizedId,
        ]);
        for (final entry in values) {
          database.execute(
            '''INSERT INTO catalog_works (source_id, work_id, payload_json, updated_at)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(source_id, work_id) DO UPDATE SET
                 payload_json = excluded.payload_json,
                 updated_at = excluded.updated_at''',
            [
              normalizedId,
              entry.work.id,
              jsonEncode(_workToJson(entry.work)),
              DateTime.now().toUtc().millisecondsSinceEpoch,
            ],
          );
        }
        database.execute('COMMIT');
      } on Object {
        database.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      database?.close();
    }
  }

  Future<void> replaceAll(Iterable<FundusCatalogEntry> entries) async {
    // Keep the mirror's uniqueness contract in sync with the unified catalog:
    // one source/work row, with an offline copy preferred over a live row.
    final normalizedEntries = FundusLibraryCatalog(entries).entries;
    final grouped = <String, List<FundusCatalogEntry>>{};
    final sources = <String, FundusCatalogSource>{};
    for (final entry in normalizedEntries) {
      grouped.putIfAbsent(entry.source.id, () => []).add(entry);
      sources[entry.source.id] = entry.source;
    }
    final target = await _resolvedFile();
    await target.parent.create(recursive: true);
    Database? database;
    try {
      database = _open(target);
      database.execute('BEGIN IMMEDIATE');
      try {
        database.execute('DELETE FROM catalog_works');
        database.execute('DELETE FROM catalog_sources');
        for (final source in sources.values) {
          _upsertSource(database, source);
        }
        for (final group in grouped.entries) {
          for (final entry in group.value) {
            database.execute(
              'INSERT INTO catalog_works (source_id, work_id, payload_json, updated_at) VALUES (?, ?, ?, ?)',
              [
                group.key,
                entry.work.id,
                jsonEncode(_workToJson(entry.work)),
                DateTime.now().toUtc().millisecondsSinceEpoch,
              ],
            );
          }
        }
        database.execute('COMMIT');
      } on Object {
        database.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      database?.close();
    }
  }

  Future<void> removeSource(String sourceId) async {
    final target = await _resolvedFile();
    if (!await target.exists()) return;
    Database? database;
    try {
      database = _open(target);
      database.execute('DELETE FROM catalog_sources WHERE id = ?', [sourceId]);
    } finally {
      database?.close();
    }
  }

  static void _upsertSource(Database database, FundusCatalogSource source) {
    database.execute(
      '''INSERT INTO catalog_sources
           (id, kind, display_name, library_name, availability, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           kind = excluded.kind,
           display_name = excluded.display_name,
           library_name = excluded.library_name,
           availability = excluded.availability,
           updated_at = excluded.updated_at''',
      [
        source.id,
        source.kind.name,
        source.displayName,
        source.libraryName,
        source.availability.name,
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  }

  static FundusCatalogSource? _sourceFromRow(Map<String, Object?> row) {
    final id = row['source_id'];
    final kind = row['source_kind'];
    final displayName = row['display_name'];
    if (id is! String || kind is! String || displayName is! String) return null;
    final parsedKind = FundusCatalogSourceKind.values
        .where((value) => value.name == kind)
        .firstOrNull;
    if (parsedKind == null) return null;
    final availability = FundusCatalogAvailability.values
        .where((value) => value.name == row['availability'])
        .firstOrNull;
    return FundusCatalogSource(
      id: id,
      kind: parsedKind,
      displayName: displayName,
      libraryName: row['library_name'] as String?,
      availability: availability ?? FundusCatalogAvailability.missing,
    );
  }

  static Map<String, Object?> _workToJson(LibraryWorkSummary work) => {
    'id': work.id,
    'kind': work.kind,
    'title': work.title,
    'author': work.author,
    'authors': work.authors,
    'file_count': work.fileCount,
    'added_at': work.addedAt.toUtc().toIso8601String(),
    'series': work.series,
    'series_sequence': work.seriesSequence,
    'cover_path': work.coverPath,
    'offline_path': work.offlinePath,
    'cover_version': work.coverVersion,
    'language': work.language,
    'subtitle': work.subtitle,
    'description': work.description,
    'narrators': work.narrators,
    'genres': work.genres,
    'publisher': work.publisher,
    'published_year': work.publishedYear,
    'isbn': work.isbn,
    'asin': work.asin,
    'explicit': work.explicit,
    'content_sensitivity': work.contentSensitivity,
    'content_style': work.contentStyle,
    'abridged': work.abridged,
    'progress_position_ms': work.progressPosition?.inMilliseconds,
    'progress_duration_ms': work.progressDuration?.inMilliseconds,
    'media_progress': work.mediaProgress?.toJson(),
    'progress_track_index': work.progressTrackIndex,
    'progress_finished': work.progressFinished,
    'status': work.status,
    'tags': work.tags,
    'last_listened_at': work.lastListenedAt?.toUtc().toIso8601String(),
    'offline': work.offline,
    'source_id': work.sourceId,
    'availability': work.availability,
    'source_server_name': work.sourceServerName,
    'source_library_name': work.sourceLibraryName,
    'provider_metadata': work.providerMetadata,
  };

  static LibraryWorkSummary? _workFromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['title'] is! String) {
      return null;
    }
    final authors = _strings(raw['authors']);
    final author = raw['author'] is String
        ? raw['author'] as String
        : authors.firstOrNull ?? 'Unbekannt';
    final addedAt = DateTime.tryParse('${raw['added_at'] ?? ''}');
    if (addedAt == null) return null;
    MediaPosition? mediaProgress;
    final position = raw['media_progress'];
    if (position is Map) {
      try {
        mediaProgress = MediaPosition.fromJson(
          Map<String, Object?>.from(position),
        );
      } on FormatException {
        mediaProgress = null;
      }
    }
    Duration? duration(Object? value) =>
        value is num ? Duration(milliseconds: value.toInt()) : null;
    final provider = raw['provider_metadata'];
    return LibraryWorkSummary(
      id: raw['id'] as String,
      kind: raw['kind'] is String ? raw['kind'] as String : 'unknown',
      title: raw['title'] as String,
      author: author,
      authors: authors.isEmpty ? [author] : authors,
      fileCount: raw['file_count'] is num
          ? (raw['file_count'] as num).toInt()
          : 0,
      addedAt: addedAt.toLocal(),
      series: raw['series'] as String?,
      seriesSequence: (raw['series_sequence'] as num?)?.toDouble(),
      coverPath: raw['cover_path'] as String?,
      offlinePath: raw['offline_path'] as String?,
      coverVersion: raw['cover_version'] as String?,
      language: raw['language'] as String?,
      subtitle: raw['subtitle'] as String?,
      description: raw['description'] as String?,
      narrators: _strings(raw['narrators']),
      genres: _strings(raw['genres']),
      publisher: raw['publisher'] as String?,
      publishedYear: (raw['published_year'] as num?)?.toInt(),
      isbn: raw['isbn'] as String?,
      asin: raw['asin'] as String?,
      explicit: raw['explicit'] as bool?,
      contentSensitivity: raw['content_sensitivity'] as String?,
      contentStyle: raw['content_style'] as String?,
      abridged: raw['abridged'] as bool?,
      progressPosition: duration(raw['progress_position_ms']),
      progressDuration: duration(raw['progress_duration_ms']),
      mediaProgress: mediaProgress,
      progressTrackIndex: (raw['progress_track_index'] as num?)?.toInt(),
      progressFinished: raw['progress_finished'] == true,
      status: raw['status'] is String ? raw['status'] as String : 'available',
      tags: _strings(raw['tags']),
      lastListenedAt: DateTime.tryParse('${raw['last_listened_at'] ?? ''}'),
      offline: raw['offline'] == true,
      sourceId: raw['source_id'] as String?,
      availability: raw['availability'] is String
          ? raw['availability'] as String
          : 'available',
      sourceServerName: raw['source_server_name'] as String?,
      sourceLibraryName: raw['source_library_name'] as String?,
      providerMetadata: provider is Map
          ? {
              for (final entry in provider.entries)
                if (entry.key is String) entry.key as String: entry.value,
            }
          : const {},
    );
  }

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];

  static Database _open(File file) {
    final database = sqlite3.open(file.path);
    database.execute('PRAGMA foreign_keys = ON');
    database.execute('PRAGMA busy_timeout = 5000');
    database.execute('''
      CREATE TABLE IF NOT EXISTS catalog_sources (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        display_name TEXT NOT NULL,
        library_name TEXT,
        availability TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS catalog_works (
        source_id TEXT NOT NULL REFERENCES catalog_sources(id) ON DELETE CASCADE,
        work_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        PRIMARY KEY (source_id, work_id)
      )
    ''');
    database.execute(
      'CREATE INDEX IF NOT EXISTS catalog_works_source_idx ON catalog_works(source_id)',
    );
    return database;
  }
}
