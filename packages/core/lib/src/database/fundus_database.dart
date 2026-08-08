import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../import/abs_importer.dart';
import '../model/fundus_id.dart';
import '../model/media_position.dart';
import '../playback/library_playback.dart';
import '../scan/library_scanner.dart';

final class LibraryWorkSummary {
  const LibraryWorkSummary({
    required this.id,
    required this.kind,
    required this.title,
    required this.author,
    required this.fileCount,
    required this.addedAt,
    this.series,
    this.seriesSequence,
    this.coverPath,
  });

  final String id;
  final String kind;
  final String title;
  final String author;
  final int fileCount;
  final DateTime addedAt;
  final String? series;
  final double? seriesSequence;
  final String? coverPath;
}

final class FundusDatabase {
  FundusDatabase._(this._database);

  static const schemaVersion = 3;

  final Database _database;

  factory FundusDatabase.openFile(File file, {bool readOnly = false}) {
    if (!readOnly) file.parent.createSync(recursive: true);
    final instance = FundusDatabase._(
      sqlite3.open(
        file.path,
        mode: readOnly ? OpenMode.readOnly : OpenMode.readWriteCreate,
      ),
    );
    instance._initialize(readOnly: readOnly);
    return instance;
  }

  factory FundusDatabase.inMemory() {
    final instance = FundusDatabase._(sqlite3.openInMemory());
    instance._initialize();
    return instance;
  }

  int get userVersion => _database.userVersion;

  bool tableExists(String name) {
    final result = _database.select(
      'SELECT 1 FROM sqlite_master WHERE type IN (\'table\', \'view\') AND name = ?',
      [name],
    );
    return result.isNotEmpty;
  }

  bool columnExists(String table, String column) {
    final safeTable = table.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (safeTable != table) return false;
    return _database
        .select('PRAGMA table_info($safeTable)')
        .any((row) => row['name'] == column);
  }

  T transaction<T>(T Function() action) {
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  String upsertFile(ScannedFile file) {
    final existing = _database.select('SELECT id FROM files WHERE path = ?', [
      file.relativePath,
    ]);
    final id = existing.isEmpty
        ? FundusId.generate()
        : existing.first['id'] as String;
    final now = DateTime.now().millisecondsSinceEpoch;
    _database.execute(
      '''
      INSERT INTO files (
        id, path, filename, extension, size, mime_type, file_modified_at,
        indexed_at, status
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'available')
      ON CONFLICT(path) DO UPDATE SET
        filename = excluded.filename,
        extension = excluded.extension,
        size = excluded.size,
        mime_type = excluded.mime_type,
        file_modified_at = excluded.file_modified_at,
        indexed_at = excluded.indexed_at,
        status = 'available'
      ''',
      [
        id,
        file.relativePath,
        file.filename,
        file.extension,
        file.size,
        file.mimeType,
        file.modifiedAt.millisecondsSinceEpoch,
        now,
      ],
    );
    return id;
  }

  String upsertAudiobookCandidate(
    AudiobookImportCandidate candidate,
    Map<String, String> fileIds,
  ) {
    final identity = candidate.identity;
    String? seriesId;
    if (identity.series case final series?) {
      seriesId = _upsertWork(
        kind: 'book_series',
        sourcePath: '${identity.author}/$series',
        title: series,
        metadata: {'author': identity.author},
      );
    }
    final workId = _upsertWork(
      kind: 'audiobook',
      sourcePath: candidate.directory,
      title: identity.title,
      parentId: seriesId,
      seriesName: identity.series,
      seriesSequence: identity.sequence,
      metadata: {'author': identity.author},
    );
    _database.execute('UPDATE works SET cover_file_id = NULL WHERE id = ?', [
      workId,
    ]);
    _database.execute('DELETE FROM work_files WHERE work_id = ?', [workId]);
    for (var index = 0; index < candidate.audioFiles.length; index++) {
      final file = candidate.audioFiles[index];
      final fileId = fileIds[file.relativePath];
      if (fileId == null) continue;
      _database.execute(
        'INSERT INTO work_files (work_id, file_id, position, role) VALUES (?, ?, ?, ?)',
        [workId, fileId, index, 'content'],
      );
    }
    for (var index = 0; index < candidate.coverFiles.length; index++) {
      final file = candidate.coverFiles[index];
      final fileId = fileIds[file.relativePath];
      if (fileId == null) continue;
      _database.execute(
        'INSERT INTO work_files (work_id, file_id, position, role) VALUES (?, ?, ?, ?)',
        [workId, fileId, index, 'cover'],
      );
      if (index == 0) {
        _database.execute('UPDATE works SET cover_file_id = ? WHERE id = ?', [
          fileId,
          workId,
        ]);
      }
    }
    _database.execute(
      "DELETE FROM search_index WHERE entity_type = 'work' AND entity_id = ?",
      [workId],
    );
    _database.execute(
      'INSERT INTO search_index (entity_type, entity_id, title, body, tags) VALUES (?, ?, ?, ?, ?)',
      [
        'work',
        workId,
        identity.title,
        '${identity.author} ${identity.series ?? ''}',
        '',
      ],
    );
    return workId;
  }

  void setGeneratedCoverPath(String workId, String? path) {
    _database.execute(
      'UPDATE works SET generated_cover_path = ? WHERE id = ?',
      [path, workId],
    );
  }

  List<LibraryWorkSummary> listWorks() {
    final rows = _database.select('''
      SELECT w.id, w.kind, w.title, w.series_name, w.series_sequence, w.added_at,
             w.metadata_json, COUNT(wf.file_id) AS file_count,
             COALESCE(cover.path, w.generated_cover_path) AS cover_path
      FROM works w
      LEFT JOIN work_files wf ON wf.work_id = w.id AND wf.role = 'content'
      LEFT JOIN files cover ON cover.id = w.cover_file_id
      WHERE w.kind != 'book_series' AND w.status = 'available'
      GROUP BY w.id
      ORDER BY COALESCE(w.series_name, w.title) COLLATE NOCASE,
               w.series_sequence, w.title COLLATE NOCASE
    ''');
    return rows
        .map((row) {
          final metadata =
              jsonDecode(row['metadata_json'] as String)
                  as Map<String, dynamic>;
          return LibraryWorkSummary(
            id: row['id'] as String,
            kind: row['kind'] as String,
            title: row['title'] as String,
            author: metadata['author'] as String? ?? 'Unbekannt',
            series: row['series_name'] as String?,
            seriesSequence: (row['series_sequence'] as num?)?.toDouble(),
            fileCount: row['file_count'] as int,
            addedAt: DateTime.fromMillisecondsSinceEpoch(
              row['added_at'] as int,
            ),
            coverPath: row['cover_path'] as String?,
          );
        })
        .toList(growable: false);
  }

  List<
    ({String fileId, String path, String title, int position, int? durationMs})
  >
  playbackTracks(String workId) {
    final rows = _database.select(
      '''
      SELECT f.id, f.path, f.filename, wf.position, f.duration_ms
      FROM work_files wf
      JOIN files f ON f.id = wf.file_id
      WHERE wf.work_id = ? AND wf.role = 'content' AND f.status = 'available'
      ORDER BY wf.position, f.filename COLLATE NOCASE
      ''',
      [workId],
    );
    return rows
        .map(
          (row) => (
            fileId: row['id'] as String,
            path: row['path'] as String,
            title: row['filename'] as String,
            position: row['position'] as int,
            durationMs: row['duration_ms'] as int?,
          ),
        )
        .toList(growable: false);
  }

  LibraryPlaybackProgress? loadProgress(String workId) {
    final rows = _database.select(
      'SELECT * FROM progress WHERE work_id = ? AND user_id = ?',
      [workId, 'default'],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return LibraryPlaybackProgress(
      workId: workId,
      fileId: row['file_id'] as String?,
      position: MediaPosition.fromJson({
        'kind': row['position_kind'] as String,
        'numeric_value': row['numeric_value'] as num?,
        'key': row['position_key'] as String?,
        'label': row['position_label'] as String?,
        'total': row['total'] as num?,
        'file_id': row['file_id'] as String?,
      }),
      finished: (row['finished'] as int) == 1,
      revision: row['revision'] as int,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  LibraryPlaybackProgress saveProgress({
    required String workId,
    required String fileId,
    required Duration position,
    Duration? duration,
    required bool finished,
    required String deviceId,
    required String operationId,
  }) {
    return transaction(() {
      final processed = _database.select(
        'SELECT 1 FROM progress_revisions WHERE operation_id = ?',
        [operationId],
      );
      if (processed.isNotEmpty) {
        return loadProgress(workId) ??
            (throw StateError(
              'Verarbeitete Fortschrittsoperation ohne Zustand.',
            ));
      }
      final revision = (loadProgress(workId)?.revision ?? 0) + 1;
      final now = DateTime.now().millisecondsSinceEpoch;
      final mediaPosition = MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: position.inMilliseconds / 1000,
        total: duration == null ? null : duration.inMilliseconds / 1000,
        fileId: fileId,
      );
      final snapshot = jsonEncode({
        'work_id': workId,
        'position': mediaPosition.toJson(),
        'finished': finished,
        'device_id': deviceId,
      });
      _database.execute(
        '''
        INSERT INTO progress (
          work_id, user_id, file_id, position_kind, numeric_value,
          position_key, position_label, total, finished, revision,
          updated_at, device_id, operation_id
        ) VALUES (?, 'default', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(work_id, user_id) DO UPDATE SET
          file_id = excluded.file_id,
          position_kind = excluded.position_kind,
          numeric_value = excluded.numeric_value,
          position_key = excluded.position_key,
          position_label = excluded.position_label,
          total = excluded.total,
          finished = excluded.finished,
          revision = excluded.revision,
          updated_at = excluded.updated_at,
          device_id = excluded.device_id,
          operation_id = excluded.operation_id
        ''',
        [
          workId,
          fileId,
          mediaPosition.kind.name,
          mediaPosition.numericValue,
          mediaPosition.key,
          mediaPosition.label,
          mediaPosition.total,
          finished ? 1 : 0,
          revision,
          now,
          deviceId,
          operationId,
        ],
      );
      _database.execute(
        '''
        INSERT INTO progress_revisions (
          work_id, user_id, revision, operation_id, snapshot_json, created_at
        ) VALUES (?, 'default', ?, ?, ?, ?)
        ''',
        [workId, revision, operationId, snapshot, now],
      );
      return loadProgress(workId)!;
    });
  }

  void markUnseenFilesMissing(Set<String> seenPaths) {
    _database.execute("UPDATE files SET status = 'missing'");
    for (final path in seenPaths) {
      _database.execute(
        "UPDATE files SET status = 'available' WHERE path = ?",
        [path],
      );
    }
  }

  String _upsertWork({
    required String kind,
    required String sourcePath,
    required String title,
    required Map<String, Object?> metadata,
    String? parentId,
    String? seriesName,
    double? seriesSequence,
  }) {
    final existing = _database.select(
      'SELECT id FROM works WHERE source_path = ?',
      [sourcePath],
    );
    final id = existing.isEmpty
        ? FundusId.generate()
        : existing.first['id'] as String;
    _database.execute(
      '''
      INSERT INTO works (
        id, kind, source_path, parent_id, title, sort_title, series_name,
        series_sequence, metadata_json, added_at, status
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'available')
      ON CONFLICT(source_path) DO UPDATE SET
        kind = excluded.kind,
        parent_id = excluded.parent_id,
        title = excluded.title,
        sort_title = excluded.sort_title,
        series_name = excluded.series_name,
        series_sequence = excluded.series_sequence,
        metadata_json = excluded.metadata_json,
        status = 'available'
      ''',
      [
        id,
        kind,
        sourcePath,
        parentId,
        title,
        title.toLowerCase(),
        seriesName,
        seriesSequence,
        jsonEncode(metadata),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  void close() => _database.close();

  void _initialize({bool readOnly = false}) {
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('PRAGMA busy_timeout = 5000');
    final current = _database.userVersion;
    if (current > schemaVersion) {
      throw StateError(
        'Datenbankschema $current ist neuer als unterstütztes Schema $schemaVersion.',
      );
    }
    if (current == 0) {
      if (readOnly) {
        throw StateError(
          'Eine neue Bibliothek kann nicht schreibgeschützt geöffnet werden.',
        );
      }
      _migrateToVersion1();
    }
    if (_database.userVersion == 1 && !readOnly) _migrateToVersion2();
    if (_database.userVersion == 2 && !readOnly) _migrateToVersion3();
  }

  void _migrateToVersion1() {
    _database.execute('BEGIN IMMEDIATE');
    try {
      for (final statement in _version1Statements) {
        _database.execute(statement);
      }
      _database.userVersion = 1;
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrateToVersion2() {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'ALTER TABLE progress_revisions ADD COLUMN operation_id TEXT',
      );
      _database.execute(
        'CREATE UNIQUE INDEX progress_revisions_operation_idx ON progress_revisions(operation_id)',
      );
      _database.userVersion = 2;
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void _migrateToVersion3() {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        'ALTER TABLE works ADD COLUMN generated_cover_path TEXT',
      );
      _database.userVersion = 3;
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }
}

const _version1Statements = <String>[
  '''
  CREATE TABLE files (
    id TEXT PRIMARY KEY,
    path TEXT NOT NULL UNIQUE,
    filename TEXT NOT NULL,
    extension TEXT NOT NULL DEFAULT '',
    size INTEGER NOT NULL CHECK (size >= 0),
    mime_type TEXT,
    content_hash TEXT,
    phash TEXT,
    width INTEGER,
    height INTEGER,
    duration_ms INTEGER,
    file_modified_at INTEGER NOT NULL,
    indexed_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'available'
      CHECK (status IN ('available', 'missing', 'offline', 'ignored'))
  )
  ''',
  'CREATE INDEX files_content_hash_idx ON files(content_hash)',
  'CREATE INDEX files_status_idx ON files(status)',
  '''
  CREATE TABLE works (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    source_path TEXT NOT NULL UNIQUE,
    parent_id TEXT REFERENCES works(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    sort_title TEXT,
    series_name TEXT,
    series_sequence REAL,
    year INTEGER,
    cover_file_id TEXT REFERENCES files(id) ON DELETE SET NULL,
    metadata_json TEXT NOT NULL DEFAULT '{}',
    added_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'available'
  )
  ''',
  'CREATE INDEX works_parent_idx ON works(parent_id)',
  'CREATE INDEX works_kind_idx ON works(kind)',
  '''
  CREATE TABLE work_files (
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0,
    role TEXT NOT NULL DEFAULT 'content'
      CHECK (role IN ('content', 'cover', 'subtitle', 'sidecar', 'attachment', 'variant')),
    target_profile TEXT,
    PRIMARY KEY (work_id, file_id, role)
  )
  ''',
  'CREATE INDEX work_files_order_idx ON work_files(work_id, role, position)',
  '''
  CREATE TABLE people (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    sort_name TEXT,
    aliases_json TEXT NOT NULL DEFAULT '[]',
    external_ids_json TEXT NOT NULL DEFAULT '{}'
  )
  ''',
  '''
  CREATE TABLE work_people (
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (work_id, person_id, role)
  )
  ''',
  '''
  CREATE TABLE progress (
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL DEFAULT 'default',
    file_id TEXT REFERENCES files(id) ON DELETE SET NULL,
    position_kind TEXT NOT NULL,
    numeric_value REAL,
    position_key TEXT,
    position_label TEXT,
    total REAL,
    finished INTEGER NOT NULL DEFAULT 0 CHECK (finished IN (0, 1)),
    revision INTEGER NOT NULL DEFAULT 1,
    updated_at INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    operation_id TEXT NOT NULL UNIQUE,
    PRIMARY KEY (work_id, user_id)
  )
  ''',
  '''
  CREATE TABLE progress_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL,
    revision INTEGER NOT NULL,
    snapshot_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE (work_id, user_id, revision)
  )
  ''',
  '''
  CREATE TABLE play_events (
    id TEXT PRIMARY KEY,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    started_at INTEGER NOT NULL,
    ended_at INTEGER,
    seconds_played INTEGER NOT NULL DEFAULT 0,
    device_id TEXT NOT NULL,
    user_id TEXT NOT NULL DEFAULT 'default'
  )
  ''',
  '''
  CREATE TABLE notes (
    id TEXT PRIMARY KEY,
    work_id TEXT REFERENCES works(id) ON DELETE CASCADE,
    file_id TEXT REFERENCES files(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL DEFAULT 'default',
    markdown TEXT NOT NULL DEFAULT '',
    revision INTEGER NOT NULL DEFAULT 1,
    updated_at INTEGER NOT NULL,
    CHECK (work_id IS NOT NULL OR file_id IS NOT NULL)
  )
  ''',
  '''
  CREATE TABLE bookmarks (
    id TEXT PRIMARY KEY,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    file_id TEXT REFERENCES files(id) ON DELETE SET NULL,
    user_id TEXT NOT NULL DEFAULT 'default',
    position_kind TEXT NOT NULL,
    numeric_value REAL,
    position_key TEXT,
    position_label TEXT,
    label TEXT,
    note TEXT,
    color TEXT,
    quote TEXT,
    created_at INTEGER NOT NULL
  )
  ''',
  'CREATE TABLE tags (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT)',
  '''
  CREATE TABLE work_tags (
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (work_id, tag_id)
  )
  ''',
  '''
  CREATE TABLE collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id TEXT REFERENCES collections(id) ON DELETE SET NULL,
    kind TEXT NOT NULL DEFAULT 'manual',
    rules_json TEXT,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE collection_works (
    collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    position INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (collection_id, work_id)
  )
  ''',
  '''
  CREATE TABLE playlists (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('manual', 'smart', 'series')),
    media_type TEXT,
    filter_json TEXT,
    sort_json TEXT NOT NULL DEFAULT '[]',
    revision INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE playlist_items (
    id TEXT PRIMARY KEY,
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    position INTEGER NOT NULL,
    UNIQUE (playlist_id, position)
  )
  ''',
  '''
  CREATE TABLE playback_sessions (
    id TEXT PRIMARY KEY,
    playlist_id TEXT REFERENCES playlists(id) ON DELETE SET NULL,
    playlist_revision INTEGER,
    current_index INTEGER NOT NULL DEFAULT 0,
    current_position_json TEXT NOT NULL,
    shuffle_order_json TEXT NOT NULL DEFAULT '[]',
    repeat_mode TEXT NOT NULL DEFAULT 'none',
    user_id TEXT NOT NULL DEFAULT 'default',
    device_id TEXT NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE playback_session_items (
    session_id TEXT NOT NULL REFERENCES playback_sessions(id) ON DELETE CASCADE,
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    file_ids_json TEXT NOT NULL DEFAULT '[]',
    position INTEGER NOT NULL,
    PRIMARY KEY (session_id, position)
  )
  ''',
  '''
  CREATE TABLE property_definitions (
    id TEXT PRIMARY KEY,
    media_kind TEXT NOT NULL,
    name TEXT NOT NULL,
    value_type TEXT NOT NULL,
    options_json TEXT,
    UNIQUE (media_kind, name)
  )
  ''',
  '''
  CREATE TABLE work_properties (
    work_id TEXT NOT NULL REFERENCES works(id) ON DELETE CASCADE,
    definition_id TEXT NOT NULL REFERENCES property_definitions(id) ON DELETE CASCADE,
    value_json TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'user',
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (work_id, definition_id)
  )
  ''',
  '''
  CREATE VIRTUAL TABLE search_index USING fts5(
    entity_type UNINDEXED,
    entity_id UNINDEXED,
    title,
    body,
    tags,
    tokenize = 'unicode61 remove_diacritics 2'
  )
  ''',
];
