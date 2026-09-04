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
    this.availability = LibrarySourceAvailability.available,
    this.lastSeenAt,
  });

  final String serverId;
  final String libraryId;
  final String serverName;
  final String libraryName;
  final List<FundusRemoteWork> works;
  final DateTime fetchedAt;

  /// Stable server fingerprint for conditional catalog refreshes.
  final String? etag;

  /// Persisted source status.  Keeping this beside the mirror means a cold
  /// start can render the last known catalog state before discovery finishes.
  final LibrarySourceAvailability availability;
  final DateTime? lastSeenAt;

  String get key => '$serverId\u0000$libraryId';

  FundusRemoteCatalogSnapshot copyWith({
    String? serverName,
    String? libraryName,
    List<FundusRemoteWork>? works,
    DateTime? fetchedAt,
    String? etag,
    LibrarySourceAvailability? availability,
    DateTime? lastSeenAt,
  }) => FundusRemoteCatalogSnapshot(
    serverId: serverId,
    libraryId: libraryId,
    serverName: serverName ?? this.serverName,
    libraryName: libraryName ?? this.libraryName,
    works: works ?? this.works,
    fetchedAt: fetchedAt ?? this.fetchedAt,
    etag: etag ?? this.etag,
    availability: availability ?? this.availability,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );

  Map<String, Object?> toJson() => {
    'server_id': serverId,
    'library_id': libraryId,
    'server_name': serverName,
    'library_name': libraryName,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    if (etag != null) 'etag': etag,
    'availability': availability.name,
    if (lastSeenAt != null)
      'last_seen_at': lastSeenAt!.toUtc().toIso8601String(),
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
    final availability = LibrarySourceAvailability.values
        .where((item) => item.name == value['availability'])
        .firstOrNull;
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
      availability: availability ?? LibrarySourceAvailability.available,
      lastSeenAt: DateTime.tryParse('${value['last_seen_at'] ?? ''}'),
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
            availability: _parseAvailability(row['availability']),
            lastSeenAt: _dateFromMilliseconds(row['last_seen_at']),
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
                 fetched_at, etag, availability, last_seen_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
            [
              snapshot.serverId,
              snapshot.libraryId,
              snapshot.serverName,
              snapshot.libraryName,
              snapshot.fetchedAt.toUtc().millisecondsSinceEpoch,
              snapshot.etag,
              snapshot.availability.name,
              snapshot.lastSeenAt?.toUtc().millisecondsSinceEpoch,
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
  ) => applySyncEntries(serverId, libraryId, entries);

  /// Applies catalog and progress journal entries atomically to the local
  /// mirror. Catalog upserts contain a server-enriched `work` payload; delete
  /// entries are tombstones and remove stale works even when the source is
  /// currently unreachable.
  Future<FundusRemoteCatalogSnapshot?> applySyncEntries(
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
      if (entry.entity == 'catalog_work') {
        final workId = entry.payload['work_id'] is String
            ? entry.payload['work_id'] as String
            : entry.entityId;
        if (workId.isEmpty) continue;
        if (entry.operation == 'delete') {
          changed = byId.remove(workId) != null || changed;
          continue;
        }
        final encoded = entry.payload['work'];
        if (encoded is! Map) continue;
        final updated = FundusRemoteWork.fromJson(encoded);
        if (updated != null) {
          byId[updated.id] = updated;
          changed = true;
        }
        continue;
      }
      if (entry.entity != 'progress' || entry.operation != 'upsert') continue;
      final workId = entry.payload['work_id'];
      final position = entry.payload['position'];
      if (workId is! String || position is! Map) continue;
      final work = byId[workId];
      if (work == null) continue;
      final numeric = (position['numeric_value'] as num?)?.toDouble();
      final total = (position['total'] as num?)?.toDouble();
      final workJson = work.toJson();
      if (numeric != null) workJson['progress_position_seconds'] = numeric;
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
      availability: current.availability,
      lastSeenAt: current.lastSeenAt,
    );
    // Update only this source inside one SQLite transaction. Rewriting the
    // complete cache here made a large multi-server catalog unnecessarily
    // expensive and allowed a concurrent refresh to overwrite another
    // source's newer rows.
    await _replaceSourceWorks(updatedSnapshot);
    return updatedSnapshot;
  }

  Future<void> _replaceSourceWorks(FundusRemoteCatalogSnapshot snapshot) async {
    final target = await _resolvedFile();
    await target.parent.create(recursive: true);
    Database? database;
    try {
      database = _open(target);
      database.execute('BEGIN IMMEDIATE');
      try {
        database.execute(
          '''INSERT INTO remote_catalog_sources (
               server_id, library_id, server_name, library_name,
               fetched_at, etag, availability, last_seen_at
             ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT(server_id, library_id) DO UPDATE SET
               server_name = excluded.server_name,
               library_name = excluded.library_name,
               fetched_at = excluded.fetched_at,
               etag = excluded.etag,
               availability = excluded.availability,
               last_seen_at = excluded.last_seen_at''',
          [
            snapshot.serverId,
            snapshot.libraryId,
            snapshot.serverName,
            snapshot.libraryName,
            snapshot.fetchedAt.toUtc().millisecondsSinceEpoch,
            snapshot.etag,
            snapshot.availability.name,
            snapshot.lastSeenAt?.toUtc().millisecondsSinceEpoch,
          ],
        );
        database.execute(
          '''DELETE FROM remote_catalog_works
             WHERE server_id = ? AND library_id = ?''',
          [snapshot.serverId, snapshot.libraryId],
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
        database.execute('COMMIT');
      } on Object {
        database.execute('ROLLBACK');
        rethrow;
      }
    } finally {
      database?.close();
    }
  }

  static String _sourceKey(String serverId, String libraryId) =>
      '$serverId\u0000$libraryId';

  static LibrarySourceAvailability _parseAvailability(Object? value) =>
      LibrarySourceAvailability.values
          .where((item) => item.name == value)
          .firstOrNull ??
      LibrarySourceAvailability.available;

  static DateTime? _dateFromMilliseconds(Object? value) => value is int
      ? DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal()
      : null;

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
        availability TEXT NOT NULL DEFAULT 'available',
        last_seen_at INTEGER,
        PRIMARY KEY (server_id, library_id)
      )
    ''');
    final sourceColumns = database
        .select('PRAGMA table_info(remote_catalog_sources)')
        .map((row) => row['name'] as String)
        .toSet();
    if (!sourceColumns.contains('availability')) {
      database.execute(
        "ALTER TABLE remote_catalog_sources ADD COLUMN availability TEXT NOT NULL DEFAULT 'available'",
      );
    }
    if (!sourceColumns.contains('last_seen_at')) {
      database.execute(
        'ALTER TABLE remote_catalog_sources ADD COLUMN last_seen_at INTEGER',
      );
    }
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
