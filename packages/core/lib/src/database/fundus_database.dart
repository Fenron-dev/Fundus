import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../import/abs_importer.dart';
import '../library/work_annotations.dart';
import '../model/fundus_id.dart';
import '../model/library_playlist.dart';
import '../model/media_position.dart';
import '../model/playback_session.dart';
import '../playback/library_playback.dart';
import '../scan/library_scanner.dart';

final class LibraryWorkSummary {
  const LibraryWorkSummary({
    required this.id,
    required this.kind,
    required this.title,
    required this.author,
    this.authors = const [],
    required this.fileCount,
    required this.addedAt,
    this.series,
    this.seriesSequence,
    this.coverPath,
    this.language,
    this.subtitle,
    this.description,
    this.narrators = const [],
    this.genres = const [],
    this.publisher,
    this.publishedYear,
    this.isbn,
    this.asin,
    this.explicit,
    this.abridged,
    this.progressPosition,
    this.progressDuration,
    this.progressTrackIndex,
    this.progressFinished = false,
  });

  final String id;
  final String kind;
  final String title;
  final String author;
  final List<String> authors;
  final int fileCount;
  final DateTime addedAt;
  final String? series;
  final double? seriesSequence;
  final String? coverPath;
  final String? language;
  final String? subtitle;
  final String? description;
  final List<String> narrators;
  final List<String> genres;
  final String? publisher;
  final int? publishedYear;
  final String? isbn;
  final String? asin;
  final bool? explicit;
  final bool? abridged;
  final Duration? progressPosition;
  final Duration? progressDuration;
  final int? progressTrackIndex;
  final bool progressFinished;
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
    Map<String, String> fileIds, {
    String? preferredWorkId,
  }) {
    var identity = candidate.identity;
    if (preferredWorkId != null &&
        candidate.usesFallbackIdentity &&
        candidate.absMetadata == null) {
      final previous = _database.select(
        'SELECT title, series_name, series_sequence, metadata_json '
        'FROM works WHERE id = ?',
        [preferredWorkId],
      );
      if (previous.isNotEmpty) {
        final row = previous.first;
        final metadata = jsonDecode(row['metadata_json'] as String);
        identity = AbsBookIdentity(
          author: metadata is Map && metadata['author'] is String
              ? metadata['author'] as String
              : identity.author,
          title: row['title'] as String,
          series: row['series_name'] as String?,
          sequence: (row['series_sequence'] as num?)?.toDouble(),
        );
      }
    }
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
      metadata: {
        'author': identity.author,
        ...?candidate.absMetadata?.toDatabaseMetadata(),
      },
      preferredId: preferredWorkId,
    );
    final previousTracks = _database.select(
      '''
      SELECT wf.file_id, wf.position, f.filename
      FROM work_files wf
      JOIN files f ON f.id = wf.file_id
      WHERE wf.work_id = ? AND wf.role = 'content'
      ORDER BY wf.position
      ''',
      [workId],
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
    _reassociateTrackReferences(
      workId,
      previousTracks,
      candidate.audioFiles,
      fileIds,
    );
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

  void _reassociateTrackReferences(
    String workId,
    ResultSet previousTracks,
    List<ScannedFile> currentTracks,
    Map<String, String> fileIds,
  ) {
    for (final previous in previousTracks) {
      final previousId = previous['file_id'] as String;
      final previousName = previous['filename'] as String;
      final previousPosition = previous['position'] as int;
      ScannedFile? replacement;
      for (final track in currentTracks) {
        if (track.filename == previousName) {
          replacement = track;
          break;
        }
      }
      if (replacement == null && previousPosition < currentTracks.length) {
        replacement = currentTracks[previousPosition];
      }
      final replacementId = replacement == null
          ? null
          : fileIds[replacement.relativePath];
      if (replacementId == null || replacementId == previousId) continue;
      _database.execute(
        'UPDATE progress SET file_id = ? WHERE work_id = ? AND file_id = ?',
        [replacementId, workId, previousId],
      );
      _database.execute(
        'UPDATE bookmarks SET file_id = ? WHERE work_id = ? AND file_id = ?',
        [replacementId, workId, previousId],
      );
    }
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
             w.metadata_json, COUNT(content.id) AS file_count,
             COALESCE(cover.path, w.generated_cover_path) AS cover_path,
             progress.numeric_value AS progress_position,
             progress.total AS progress_total,
             progress.finished AS progress_finished,
             progress_file.position AS progress_track_index
      FROM works w
      LEFT JOIN work_files wf ON wf.work_id = w.id AND wf.role = 'content'
      LEFT JOIN files content ON content.id = wf.file_id
        AND content.status = 'available'
      LEFT JOIN files cover ON cover.id = w.cover_file_id
        AND cover.status = 'available'
      LEFT JOIN progress ON progress.work_id = w.id
        AND progress.user_id = 'default'
      LEFT JOIN work_files progress_file ON progress_file.work_id = w.id
        AND progress_file.file_id = progress.file_id
        AND progress_file.role = 'content'
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
          final author = metadata['author'] as String? ?? 'Unbekannt';
          final authors = _metadataStrings(metadata['authors']);
          return LibraryWorkSummary(
            id: row['id'] as String,
            kind: row['kind'] as String,
            title: row['title'] as String,
            author: author,
            authors: authors.isEmpty ? [author] : authors,
            series: row['series_name'] as String?,
            seriesSequence: (row['series_sequence'] as num?)?.toDouble(),
            fileCount: row['file_count'] as int,
            addedAt: DateTime.fromMillisecondsSinceEpoch(
              row['added_at'] as int,
            ),
            coverPath: row['cover_path'] as String?,
            language: metadata['language'] as String?,
            subtitle: metadata['subtitle'] as String?,
            description: metadata['description'] as String?,
            narrators: _metadataStrings(metadata['narrators']),
            genres: _metadataStrings(metadata['genres']),
            publisher: metadata['publisher'] as String?,
            publishedYear: (metadata['published_year'] as num?)?.round(),
            isbn: metadata['isbn'] as String?,
            asin: metadata['asin'] as String?,
            explicit: metadata['explicit'] as bool?,
            abridged: metadata['abridged'] as bool?,
            progressPosition: _seconds(row['progress_position']),
            progressDuration: _seconds(row['progress_total']),
            progressTrackIndex: row['progress_track_index'] as int?,
            progressFinished: (row['progress_finished'] as int?) == 1,
          );
        })
        .toList(growable: false);
  }

  static List<String> _metadataStrings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];

  static Duration? _seconds(Object? value) {
    if (value is! num || !value.isFinite || value < 0) return null;
    return Duration(
      microseconds: (value * Duration.microsecondsPerSecond).round(),
    );
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

  void savePlaybackSession(
    PlaybackSession session, {
    String userId = 'default',
    String deviceId = 'desktop-local',
  }) {
    session.validate();
    transaction(() {
      final now = DateTime.now().millisecondsSinceEpoch;
      _database.execute(
        '''
        INSERT INTO playback_sessions (
          id, playlist_id, playlist_revision, current_index,
          current_position_json, shuffle_order_json, repeat_mode,
          user_id, device_id, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          playlist_id = excluded.playlist_id,
          playlist_revision = excluded.playlist_revision,
          current_index = excluded.current_index,
          current_position_json = excluded.current_position_json,
          shuffle_order_json = excluded.shuffle_order_json,
          repeat_mode = excluded.repeat_mode,
          user_id = excluded.user_id,
          device_id = excluded.device_id,
          updated_at = excluded.updated_at
        ''',
        [
          session.id,
          session.playlistId,
          session.playlistRevision,
          session.currentIndex,
          jsonEncode(session.currentPosition.toJson()),
          jsonEncode(session.shuffleOrder),
          session.repeatMode.name,
          userId,
          deviceId,
          now,
        ],
      );
      _database.execute(
        'DELETE FROM playback_session_items WHERE session_id = ?',
        [session.id],
      );
      for (final item in session.items) {
        _database.execute(
          '''
          INSERT INTO playback_session_items (
            session_id, work_id, file_ids_json, position
          ) VALUES (?, ?, ?, ?)
          ''',
          [session.id, item.workId, jsonEncode(item.fileIds), item.position],
        );
      }
    });
  }

  PlaybackSession? loadPlaybackSession(String sessionId) {
    final rows = _database.select(
      'SELECT * FROM playback_sessions WHERE id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    return _playbackSessionFromRow(rows.first);
  }

  PlaybackSession? latestPlaybackSession({String userId = 'default'}) {
    final rows = _database.select(
      '''
      SELECT * FROM playback_sessions
      WHERE user_id = ?
      ORDER BY updated_at DESC
      LIMIT 1
      ''',
      [userId],
    );
    if (rows.isEmpty) return null;
    return _playbackSessionFromRow(rows.first);
  }

  PlaybackSession _playbackSessionFromRow(Row row) {
    final sessionId = row['id'] as String;
    final itemRows = _database.select(
      '''
      SELECT work_id, file_ids_json, position
      FROM playback_session_items
      WHERE session_id = ?
      ORDER BY position
      ''',
      [sessionId],
    );
    final positionJson = jsonDecode(row['current_position_json'] as String);
    final shuffleJson = jsonDecode(row['shuffle_order_json'] as String);
    final repeatName = row['repeat_mode'] as String;
    final session = PlaybackSession(
      id: sessionId,
      playlistId: row['playlist_id'] as String?,
      playlistRevision: row['playlist_revision'] as int?,
      items: [
        for (final item in itemRows)
          PlaybackSessionItem(
            workId: item['work_id'] as String,
            fileIds: (jsonDecode(item['file_ids_json'] as String) as List)
                .cast<String>(),
            position: item['position'] as int,
          ),
      ],
      currentIndex: row['current_index'] as int,
      currentPosition: MediaPosition.fromJson(
        (positionJson as Map).cast<String, Object?>(),
      ),
      repeatMode: RepeatMode.values.firstWhere(
        (mode) => mode.name == repeatName,
        orElse: () => RepeatMode.none,
      ),
      shuffleOrder: (shuffleJson as List).cast<int>(),
    );
    session.validate();
    return session;
  }

  List<LibraryPlaylist> listPlaylists() {
    final rows = _database.select(
      'SELECT * FROM playlists ORDER BY name COLLATE NOCASE, updated_at DESC',
    );
    return rows.map(_playlistFromRow).toList(growable: false);
  }

  LibraryPlaylist? loadPlaylist(String playlistId) {
    final rows = _database.select('SELECT * FROM playlists WHERE id = ?', [
      playlistId,
    ]);
    return rows.isEmpty ? null : _playlistFromRow(rows.first);
  }

  LibraryPlaylist savePlaylist({
    String? playlistId,
    required String name,
    required List<String> workIds,
    LibraryPlaylistKind kind = LibraryPlaylistKind.manual,
    String? mediaType,
  }) {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Playlistname ist leer.');
    }
    final normalizedMediaType = mediaType?.trim();
    final id = playlistId ?? FundusId.generate();
    return transaction(() {
      final previous = _database.select(
        'SELECT revision, created_at FROM playlists WHERE id = ?',
        [id],
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final revision = previous.isEmpty
          ? 1
          : (previous.first['revision'] as int) + 1;
      final createdAt = previous.isEmpty
          ? now
          : previous.first['created_at'] as int;
      _database.execute(
        '''
        INSERT INTO playlists (
          id, name, kind, media_type, revision, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          name = excluded.name,
          kind = excluded.kind,
          media_type = excluded.media_type,
          revision = excluded.revision,
          updated_at = excluded.updated_at
        ''',
        [
          id,
          normalizedName,
          kind.name,
          normalizedMediaType == null || normalizedMediaType.isEmpty
              ? null
              : normalizedMediaType,
          revision,
          createdAt,
          now,
        ],
      );
      _database.execute('DELETE FROM playlist_items WHERE playlist_id = ?', [
        id,
      ]);
      for (var position = 0; position < workIds.length; position++) {
        _database.execute(
          '''
          INSERT INTO playlist_items (id, playlist_id, work_id, position)
          VALUES (?, ?, ?, ?)
          ''',
          [FundusId.generate(), id, workIds[position], position],
        );
      }
      return loadPlaylist(id)!;
    });
  }

  void deletePlaylist(String playlistId) {
    _database.execute('DELETE FROM playlists WHERE id = ?', [playlistId]);
  }

  LibraryPlaylist _playlistFromRow(Row row) {
    final id = row['id'] as String;
    final items = _database.select(
      '''
      SELECT work_id FROM playlist_items
      WHERE playlist_id = ?
      ORDER BY position
      ''',
      [id],
    );
    final kindName = row['kind'] as String;
    return LibraryPlaylist(
      id: id,
      name: row['name'] as String,
      kind: LibraryPlaylistKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => LibraryPlaylistKind.manual,
      ),
      mediaType: row['media_type'] as String?,
      workIds: items.map((item) => item['work_id'] as String).toList(),
      revision: row['revision'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  String? workSourcePath(String workId) {
    final rows = _database.select(
      'SELECT source_path FROM works WHERE id = ?',
      [workId],
    );
    return rows.isEmpty ? null : rows.first['source_path'] as String;
  }

  String? workLanguage(String workId) {
    final rows = _database.select(
      'SELECT metadata_json FROM works WHERE id = ?',
      [workId],
    );
    if (rows.isEmpty) return null;
    final metadata =
        jsonDecode(rows.first['metadata_json'] as String)
            as Map<String, dynamic>;
    return metadata['language'] as String?;
  }

  void setWorkLanguage(String workId, String? language) {
    final rows = _database.select(
      'SELECT metadata_json FROM works WHERE id = ?',
      [workId],
    );
    if (rows.isEmpty) return;
    final metadata =
        jsonDecode(rows.first['metadata_json'] as String)
            as Map<String, dynamic>;
    final normalized = language?.trim();
    if (normalized == null || normalized.isEmpty) {
      metadata.remove('language');
    } else {
      metadata['language'] = normalized;
    }
    _database.execute('UPDATE works SET metadata_json = ? WHERE id = ?', [
      jsonEncode(metadata),
      workId,
    ]);
  }

  List<String> listTags() => _database
      .select('SELECT name FROM tags ORDER BY name COLLATE NOCASE')
      .map((row) => row['name'] as String)
      .toList(growable: false);

  WorkAnnotations loadAnnotations(String workId) {
    final tagRows = _database.select(
      '''
      SELECT t.name
      FROM work_tags wt
      JOIN tags t ON t.id = wt.tag_id
      WHERE wt.work_id = ?
      ORDER BY t.name COLLATE NOCASE
      ''',
      [workId],
    );
    final noteRows = _database.select(
      '''
      SELECT id, markdown, updated_at
      FROM notes
      WHERE work_id = ? AND user_id = 'default'
      ORDER BY updated_at DESC, rowid DESC
      ''',
      [workId],
    );
    final bookmarkRows = _database.select(
      '''
      SELECT id, file_id, numeric_value, label, note, created_at
      FROM bookmarks
      WHERE work_id = ? AND user_id = 'default'
      ORDER BY numeric_value, created_at
      ''',
      [workId],
    );
    return WorkAnnotations(
      tags: tagRows.map((row) => row['name'] as String).toList(growable: false),
      note: noteRows.isEmpty ? '' : noteRows.first['markdown'] as String,
      notes: noteRows
          .map(
            (row) => LibraryNote(
              id: row['id'] as String,
              markdown: row['markdown'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                row['updated_at'] as int,
              ),
            ),
          )
          .toList(growable: false),
      bookmarks: bookmarkRows
          .map(
            (row) => LibraryBookmark(
              id: row['id'] as String,
              workId: workId,
              fileId: row['file_id'] as String?,
              position: Duration(
                milliseconds: (((row['numeric_value'] as num?) ?? 0) * 1000)
                    .round(),
              ),
              label: row['label'] as String?,
              note: row['note'] as String?,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                row['created_at'] as int,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  void replaceWorkTags(String workId, Iterable<String> names) {
    final normalized =
        {
            for (final name in names)
              if (name.trim().isNotEmpty) name.trim(),
          }.toList(growable: false)
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    transaction(() {
      _database.execute('DELETE FROM work_tags WHERE work_id = ?', [workId]);
      for (final name in normalized) {
        final existing = _database.select(
          'SELECT id FROM tags WHERE name = ? COLLATE NOCASE',
          [name],
        );
        final tagId = existing.isEmpty
            ? FundusId.generate()
            : existing.first['id'] as String;
        if (existing.isEmpty) {
          _database.execute('INSERT INTO tags (id, name) VALUES (?, ?)', [
            tagId,
            name,
          ]);
        }
        _database.execute(
          'INSERT INTO work_tags (work_id, tag_id) VALUES (?, ?)',
          [workId, tagId],
        );
      }
    });
  }

  void saveWorkNote(String workId, String markdown, {DateTime? updatedAt}) {
    final now = (updatedAt ?? DateTime.now()).millisecondsSinceEpoch;
    _database.execute(
      '''
      INSERT INTO notes (id, work_id, user_id, markdown, revision, updated_at)
      VALUES (?, ?, 'default', ?, 1, ?)
      ''',
      [FundusId.generate(), workId, markdown, now],
    );
  }

  LibraryBookmark addBookmark({
    required String workId,
    required String fileId,
    required Duration position,
    String? label,
    String? note,
    String? id,
    DateTime? createdAt,
  }) {
    var bookmarkId = id ?? FundusId.generate();
    if (id != null) {
      final existing = _database.select(
        'SELECT work_id FROM bookmarks WHERE id = ?',
        [id],
      );
      if (existing.isNotEmpty && existing.first['work_id'] != workId) {
        bookmarkId = FundusId.generate();
      }
    }
    final bookmark = LibraryBookmark(
      id: bookmarkId,
      workId: workId,
      fileId: fileId,
      position: position,
      label: label?.trim().isEmpty ?? true ? null : label!.trim(),
      note: note?.trim().isEmpty ?? true ? null : note!.trim(),
      createdAt: createdAt ?? DateTime.now(),
    );
    _database.execute(
      '''
      INSERT INTO bookmarks (
        id, work_id, file_id, user_id, position_kind, numeric_value,
        label, note, created_at
      ) VALUES (?, ?, ?, 'default', 'time', ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        file_id = excluded.file_id,
        numeric_value = excluded.numeric_value,
        label = excluded.label,
        note = excluded.note
      ''',
      [
        bookmark.id,
        bookmark.workId,
        bookmark.fileId,
        bookmark.position.inMilliseconds / 1000,
        bookmark.label,
        bookmark.note,
        bookmark.createdAt.millisecondsSinceEpoch,
      ],
    );
    return bookmark;
  }

  void deleteBookmark(String bookmarkId) =>
      _database.execute('DELETE FROM bookmarks WHERE id = ?', [bookmarkId]);

  void markUnseenFilesMissing(Set<String> seenPaths) {
    _database.execute("UPDATE files SET status = 'missing'");
    for (final path in seenPaths) {
      _database.execute(
        "UPDATE files SET status = 'available' WHERE path = ?",
        [path],
      );
    }
  }

  String? findMovedAudiobookWorkId(AudiobookImportCandidate candidate) {
    final destination = _database.select(
      'SELECT id FROM works WHERE source_path = ?',
      [candidate.directory],
    );
    if (destination.isNotEmpty) return null;
    final expected = _fileSignature(candidate.audioFiles);
    final staleWorks = _database.select(
      '''
      SELECT w.id
      FROM works w
      WHERE w.kind = 'audiobook' AND w.source_path != ?
        AND NOT EXISTS (
          SELECT 1 FROM work_files wf
          JOIN files f ON f.id = wf.file_id
          WHERE wf.work_id = w.id AND wf.role = 'content'
            AND f.status = 'available'
        )
    ''',
      [candidate.directory],
    );
    final matches = <String>[];
    for (final row in staleWorks) {
      final workId = row['id'] as String;
      final files = _database.select(
        '''
        SELECT f.filename, f.size
        FROM work_files wf
        JOIN files f ON f.id = wf.file_id
        WHERE wf.work_id = ? AND wf.role = 'content'
      ''',
        [workId],
      );
      final actual = <String, int>{};
      for (final file in files) {
        final key = '${file['filename']}\u0000${file['size']}';
        actual[key] = (actual[key] ?? 0) + 1;
      }
      if (_sameSignature(expected, actual)) matches.add(workId);
    }
    return matches.length == 1 ? matches.single : null;
  }

  void markWorksWithoutAvailableContentMissing() {
    _database.execute('''
      UPDATE works SET status = 'missing'
      WHERE kind != 'book_series' AND NOT EXISTS (
        SELECT 1 FROM work_files wf
        JOIN files f ON f.id = wf.file_id
        WHERE wf.work_id = works.id AND wf.role = 'content'
          AND f.status = 'available'
      )
    ''');
  }

  static Map<String, int> _fileSignature(Iterable<ScannedFile> files) {
    final signature = <String, int>{};
    for (final file in files) {
      final key = '${file.filename}\u0000${file.size}';
      signature[key] = (signature[key] ?? 0) + 1;
    }
    return signature;
  }

  static bool _sameSignature(Map<String, int> left, Map<String, int> right) {
    if (left.isEmpty || left.length != right.length) return false;
    for (final entry in left.entries) {
      if (right[entry.key] != entry.value) return false;
    }
    return true;
  }

  String _upsertWork({
    required String kind,
    required String sourcePath,
    required String title,
    required Map<String, Object?> metadata,
    String? parentId,
    String? seriesName,
    double? seriesSequence,
    String? preferredId,
  }) {
    final existing = _database.select(
      'SELECT id FROM works WHERE source_path = ?',
      [sourcePath],
    );
    final preferred = preferredId == null
        ? null
        : _database.select('SELECT id FROM works WHERE id = ?', [preferredId]);
    final targetId = preferred?.isNotEmpty ?? false
        ? preferredId
        : existing.isEmpty
        ? null
        : existing.first['id'] as String;
    final mergedMetadata = <String, Object?>{};
    if (targetId != null) {
      final previous = _database.select(
        'SELECT metadata_json FROM works WHERE id = ?',
        [targetId],
      );
      if (previous.isNotEmpty) {
        final decoded = jsonDecode(previous.first['metadata_json'] as String);
        if (decoded is Map<String, dynamic>) mergedMetadata.addAll(decoded);
      }
    }
    mergedMetadata.addAll(metadata);
    if (preferred?.isNotEmpty ?? false) {
      if (existing.isNotEmpty && existing.first['id'] != preferredId) {
        _mergeWorkIntoPreferred(existing.first['id'] as String, preferredId!);
      }
      _database.execute(
        '''
        UPDATE works SET kind = ?, source_path = ?, parent_id = ?, title = ?,
          sort_title = ?, series_name = ?, series_sequence = ?, metadata_json = ?,
          status = 'available'
        WHERE id = ?
        ''',
        [
          kind,
          sourcePath,
          parentId,
          title,
          title.toLowerCase(),
          seriesName,
          seriesSequence,
          jsonEncode(mergedMetadata),
          preferredId,
        ],
      );
      return preferredId!;
    }
    final id = existing.isEmpty
        ? preferredId ?? FundusId.generate()
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
        jsonEncode(mergedMetadata),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return id;
  }

  void _mergeWorkIntoPreferred(String obsoleteId, String preferredId) {
    if (obsoleteId == preferredId) return;
    final preferredProgress = _database.select(
      'SELECT updated_at FROM progress WHERE work_id = ? AND user_id = ?',
      [preferredId, 'default'],
    );
    final obsoleteProgress = _database.select(
      'SELECT updated_at FROM progress WHERE work_id = ? AND user_id = ?',
      [obsoleteId, 'default'],
    );
    if (obsoleteProgress.isNotEmpty &&
        (preferredProgress.isEmpty ||
            (obsoleteProgress.first['updated_at'] as int) >
                (preferredProgress.first['updated_at'] as int))) {
      _database.execute(
        'DELETE FROM progress WHERE work_id = ? AND user_id = ?',
        [preferredId, 'default'],
      );
      _database.execute('UPDATE progress SET work_id = ? WHERE work_id = ?', [
        preferredId,
        obsoleteId,
      ]);
    }

    _copyWorkLinks('work_tags', ['work_id', 'tag_id'], obsoleteId, preferredId);
    _copyWorkLinks(
      'work_files',
      ['work_id', 'file_id', 'position', 'role', 'target_profile'],
      obsoleteId,
      preferredId,
    );
    _copyWorkLinks(
      'work_people',
      ['work_id', 'person_id', 'role', 'position'],
      obsoleteId,
      preferredId,
    );
    _copyWorkLinks(
      'collection_works',
      ['collection_id', 'work_id', 'position'],
      obsoleteId,
      preferredId,
    );
    _copyWorkLinks(
      'work_properties',
      ['work_id', 'definition_id', 'value_json', 'source', 'updated_at'],
      obsoleteId,
      preferredId,
    );
    for (final table in const [
      'notes',
      'bookmarks',
      'play_events',
      'playlist_items',
      'playback_session_items',
    ]) {
      _database.execute('UPDATE $table SET work_id = ? WHERE work_id = ?', [
        preferredId,
        obsoleteId,
      ]);
    }
    _database.execute('UPDATE works SET parent_id = ? WHERE parent_id = ?', [
      preferredId,
      obsoleteId,
    ]);
    _database.execute(
      "DELETE FROM search_index WHERE entity_type = 'work' AND entity_id = ?",
      [obsoleteId],
    );
    _database.execute('DELETE FROM works WHERE id = ?', [obsoleteId]);
  }

  void _copyWorkLinks(
    String table,
    List<String> columns,
    String obsoleteId,
    String preferredId,
  ) {
    final selectColumns = columns
        .map((column) => column == 'work_id' ? '?' : column)
        .join(', ');
    _database.execute(
      'INSERT OR IGNORE INTO $table (${columns.join(', ')}) '
      'SELECT $selectColumns FROM $table WHERE work_id = ?',
      [preferredId, obsoleteId],
    );
    _database.execute('DELETE FROM $table WHERE work_id = ?', [obsoleteId]);
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
