import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:fundus_core/fundus_core.dart';

import 'fundus_remote_client.dart';

/// Small portable cache for remote work summaries.
///
/// The cache is metadata only: media bytes, credentials and absolute paths are
/// never stored here. Keeping it outside the vault makes the normal library
/// usable while a peer is asleep or temporarily unreachable.
final class FundusRemoteCatalogSnapshot {
  const FundusRemoteCatalogSnapshot({
    required this.serverId,
    required this.libraryId,
    required this.serverName,
    required this.libraryName,
    required this.works,
    required this.fetchedAt,
    this.etag,
  });

  final String serverId;
  final String libraryId;
  final String serverName;
  final String libraryName;
  final List<FundusRemoteWork> works;
  final DateTime fetchedAt;

  /// Stable server fingerprint for conditional catalog refreshes.
  final String? etag;

  String get key => '$serverId\u0000$libraryId';

  Map<String, Object?> toJson() => {
    'server_id': serverId,
    'library_id': libraryId,
    'server_name': serverName,
    'library_name': libraryName,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    if (etag != null) 'etag': etag,
    'works': works.map((work) => work.toJson()).toList(growable: false),
  };

  static FundusRemoteCatalogSnapshot? fromJson(Object? value) {
    if (value is! Map ||
        value['server_id'] is! String ||
        value['library_id'] is! String ||
        value['server_name'] is! String ||
        value['library_name'] is! String ||
        value['works'] is! List) {
      return null;
    }
    final fetchedAt = DateTime.tryParse('${value['fetched_at'] ?? ''}');
    if (fetchedAt == null) return null;
    return FundusRemoteCatalogSnapshot(
      serverId: value['server_id'] as String,
      libraryId: value['library_id'] as String,
      serverName: value['server_name'] as String,
      libraryName: value['library_name'] as String,
      works: (value['works'] as List)
          .map(FundusRemoteWork.fromJson)
          .whereType<FundusRemoteWork>()
          .toList(growable: false),
      fetchedAt: fetchedAt.toLocal(),
      etag: value['etag'] is String ? value['etag'] as String : null,
    );
  }
}

final class FundusRemoteCatalogStore {
  const FundusRemoteCatalogStore({this.file});

  final File? file;

  Future<File> _resolvedFile() async {
    if (file != null) return file!;
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, 'remote-catalog.db'));
  }

  Future<List<FundusRemoteCatalogSnapshot>> load() async {
    final target = await _resolvedFile();
    if (!await target.exists()) {
      // Older releases kept the cache as one JSON document. Read it once and
      // migrate it to SQLite so an upgrade never loses remote metadata.
      final legacy = File(p.join(target.parent.path, 'remote-catalog.json'));
      final migrated = await _loadLegacy(legacy);
      if (migrated.isEmpty) return const [];
      await save(migrated);
      return migrated;
    }
    Database? database;
    try {
      database = _open(target);
      final sources = database.select(
        'SELECT * FROM remote_catalog_sources ORDER BY server_id, library_id',
      );
      final works = database.select(
        'SELECT * FROM remote_catalog_works ORDER BY server_id, library_id, work_id',
      );
      final worksBySource = <String, List<FundusRemoteWork>>{};
      for (final row in works) {
        final decoded = jsonDecode(row['payload_json'] as String);
        final work = FundusRemoteWork.fromJson(decoded);
        if (work == null) continue;
        final key = _sourceKey(
          row['server_id'] as String,
          row['library_id'] as String,
        );
        (worksBySource[key] ??= <FundusRemoteWork>[]).add(work);
      }
      return [
        for (final row in sources)
          FundusRemoteCatalogSnapshot(
            serverId: row['server_id'] as String,
            libraryId: row['library_id'] as String,
            serverName: row['server_name'] as String,
            libraryName: row['library_name'] as String,
            works:
                worksBySource[_sourceKey(
                  row['server_id'] as String,
                  row['library_id'] as String,
                )] ??
                const [],
            fetchedAt: DateTime.fromMillisecondsSinceEpoch(
              row['fetched_at'] as int,
              isUtc: true,
            ).toLocal(),
            etag: row['etag'] as String?,
          ),
      ];
    } on SqliteException {
      return const [];
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    } finally {
      database?.close();
    }
  }

  Future<void> save(Iterable<FundusRemoteCatalogSnapshot> snapshots) async {
    final target = await _resolvedFile();
    await target.parent.create(recursive: true);
    Database? database;
    try {
      database = _open(target);
      final normalized = snapshots.toList(growable: false);
      database.execute('BEGIN');
      try {
        database.execute('DELETE FROM remote_catalog_works');
        database.execute('DELETE FROM remote_catalog_sources');
        for (final snapshot in normalized) {
          database.execute(
            '''INSERT INTO remote_catalog_sources (
                 server_id, library_id, server_name, library_name,
                 fetched_at, etag
               ) VALUES (?, ?, ?, ?, ?, ?)''',
            [
              snapshot.serverId,
              snapshot.libraryId,
              snapshot.serverName,
              snapshot.libraryName,
              snapshot.fetchedAt.toUtc().millisecondsSinceEpoch,
              snapshot.etag,
            ],
          );
          for (final work in snapshot.works) {
            database.execute(
              '''INSERT INTO remote_catalog_works (
                   server_id, library_id, work_id, payload_json
                 ) VALUES (?, ?, ?, ?)''',
              [
                snapshot.serverId,
                snapshot.libraryId,
                work.id,
                jsonEncode(work.toJson()),
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

  /// Returns the last server journal cursor acknowledged by this device.
  /// Cursors are kept per source so reconnecting one server never causes
  /// another server's changes to be skipped.
  Future<int> loadSyncCursor(String serverId, String libraryId) async {
    final target = await _resolvedFile();
    if (!await target.exists()) return 0;
    Database? database;
    try {
      database = _open(target);
      final rows = database.select(
        '''SELECT cursor FROM remote_catalog_sync
           WHERE server_id = ? AND library_id = ?''',
        [serverId, libraryId],
      );
      return rows.isEmpty ? 0 : (rows.single['cursor'] as int);
    } on SqliteException {
      return 0;
    } finally {
      database?.close();
    }
  }

  Future<void> saveSyncCursor(
    String serverId,
    String libraryId,
    int cursor,
  ) async {
    final target = await _resolvedFile();
    await target.parent.create(recursive: true);
    Database? database;
    try {
      database = _open(target);
      database.execute(
        '''INSERT INTO remote_catalog_sync (server_id, library_id, cursor)
           VALUES (?, ?, ?)
           ON CONFLICT(server_id, library_id) DO UPDATE SET cursor = excluded.cursor''',
        [serverId, libraryId, cursor < 0 ? 0 : cursor],
      );
    } finally {
      database?.close();
    }
  }

  /// Applies progress journal entries to the cached summaries. This keeps the
  /// dashboard current after another device reads a title, without waiting
  /// for the next full catalog refresh.
  Future<FundusRemoteCatalogSnapshot?> applySyncProgress(
    String serverId,
    String libraryId,
    Iterable<LibrarySyncJournalEntry> entries,
  ) async {
    final snapshots = await load();
    final sourceKey = _sourceKey(serverId, libraryId);
    final index = snapshots.indexWhere((snapshot) => snapshot.key == sourceKey);
    if (index < 0) return null;
    final current = snapshots[index];
    final byId = {for (final work in current.works) work.id: work};
    var changed = false;
    for (final entry in entries) {
      if (entry.entity != 'progress' || entry.operation != 'upsert') continue;
      final workId = entry.payload['work_id'];
      final position = entry.payload['position'];
      if (workId is! String || position is! Map) continue;
      final work = byId[workId];
      if (work == null) continue;
      final numeric = (position['numeric_value'] as num?)?.toDouble();
      final total = (position['total'] as num?)?.toDouble();
      final workJson = work.toJson();
      if (numeric != null) {
        workJson['progress_position_seconds'] = numeric;
      }
      if (total != null) workJson['progress_duration_seconds'] = total;
      workJson['progress_finished'] = entry.payload['finished'] == true;
      workJson['last_listened_at'] = entry.createdAt.toUtc().toIso8601String();
      final updated = FundusRemoteWork.fromJson(workJson);
      if (updated != null) {
        byId[workId] = updated;
        changed = true;
      }
    }
    if (!changed) return current;
    final updatedSnapshot = FundusRemoteCatalogSnapshot(
      serverId: current.serverId,
      libraryId: current.libraryId,
      serverName: current.serverName,
      libraryName: current.libraryName,
      works: byId.values.toList(growable: false),
      fetchedAt: current.fetchedAt,
      etag: current.etag,
    );
    final replacement = [
      for (var i = 0; i < snapshots.length; i++)
        i == index ? updatedSnapshot : snapshots[i],
    ];
    await save(replacement);
    return updatedSnapshot;
  }

  static String _sourceKey(String serverId, String libraryId) =>
      '$serverId\u0000$libraryId';

  static Database _open(File target) {
    final database = sqlite3.open(target.path);
    database.execute('''
      CREATE TABLE IF NOT EXISTS remote_catalog_sources (
        server_id TEXT NOT NULL,
        library_id TEXT NOT NULL,
        server_name TEXT NOT NULL,
        library_name TEXT NOT NULL,
        fetched_at INTEGER NOT NULL,
        etag TEXT,
        PRIMARY KEY (server_id, library_id)
      )
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS remote_catalog_works (
        server_id TEXT NOT NULL,
        library_id TEXT NOT NULL,
        work_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        PRIMARY KEY (server_id, library_id, work_id),
        FOREIGN KEY (server_id, library_id)
          REFERENCES remote_catalog_sources(server_id, library_id)
          ON DELETE CASCADE
      )
    ''');
    database.execute('''
      CREATE INDEX IF NOT EXISTS remote_catalog_works_source_idx
      ON remote_catalog_works(server_id, library_id)
    ''');
    database.execute('''
      CREATE TABLE IF NOT EXISTS remote_catalog_sync (
        server_id TEXT NOT NULL,
        library_id TEXT NOT NULL,
        cursor INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (server_id, library_id)
      )
    ''');
    database.execute('PRAGMA foreign_keys = ON');
    return database;
  }

  static Future<List<FundusRemoteCatalogSnapshot>> _loadLegacy(
    File legacy,
  ) async {
    if (!await legacy.exists()) return const [];
    try {
      final decoded = jsonDecode(await legacy.readAsString());
      if (decoded is! List) return const [];
      return decoded
          .map(FundusRemoteCatalogSnapshot.fromJson)
          .whereType<FundusRemoteCatalogSnapshot>()
          .toList(growable: false);
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }
}
