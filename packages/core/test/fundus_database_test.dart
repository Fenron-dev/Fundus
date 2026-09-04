import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('current schema is created atomically with FTS and session tables', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    expect(database.userVersion, FundusDatabase.schemaVersion);
    expect(database.tableExists('files'), isTrue);
    expect(database.tableExists('works'), isTrue);
    expect(database.tableExists('playback_sessions'), isTrue);
    expect(database.columnExists('playback_sessions', 'revision'), isTrue);
    expect(database.columnExists('files', 'audio_codec'), isTrue);
    expect(database.columnExists('files', 'sample_rate_hz'), isTrue);
    expect(database.columnExists('files', 'video_episode_json'), isTrue);
    expect(
      database.columnExists('progress', 'position_schema_version'),
      isTrue,
    );
    expect(database.columnExists('progress', 'chapter_id'), isTrue);
    expect(database.columnExists('progress', 'element_id'), isTrue);
    expect(database.columnExists('progress', 'scroll_offset'), isTrue);
    expect(database.tableExists('search_index'), isTrue);
    expect(database.tableExists('sync_journal'), isTrue);
    expect(database.tableExists('sources'), isTrue);
    expect(database.columnExists('files', 'source_id'), isTrue);
    expect(database.columnExists('files', 'availability'), isTrue);
    expect(database.columnExists('files', 'offline_path'), isTrue);
    expect(database.columnExists('works', 'source_id'), isTrue);
    expect(database.columnExists('works', 'availability'), isTrue);
  });

  test('offline materialization keeps canonical file identity intact', () {
    final database = FundusDatabase.inMemory(sourceId: 'vault:local');
    addTearDown(database.close);
    final fileId = database.upsertFile(
      ScannedFile(
        absolutePath: '/vault/Manga/Kapitel 1.cbz',
        relativePath: 'Manga/Kapitel 1.cbz',
        filename: 'Kapitel 1.cbz',
        extension: 'cbz',
        size: 42,
        modifiedAt: DateTime.utc(2026, 9, 4),
        mimeType: 'application/vnd.comicbook+zip',
      ),
    );

    final sameFileId = database.upsertFile(
      ScannedFile(
        absolutePath: '/vault/Manga/Kapitel 1.cbz',
        relativePath: 'Manga/Kapitel 1.cbz',
        filename: 'Kapitel 1.cbz',
        extension: 'cbz',
        size: 42,
        modifiedAt: DateTime.utc(2026, 9, 4),
        mimeType: 'application/vnd.comicbook+zip',
      ),
    );
    expect(sameFileId, fileId);

    database.setFileOfflinePath(fileId, '/device/offline/work-1/0001.cbz');

    expect(database.fileOfflinePath(fileId), '/device/offline/work-1/0001.cbz');
    expect(database.sourceId, 'vault:local');
    database.setFileOfflinePath(fileId, null);
    expect(database.fileOfflinePath(fileId), isNull);
  });

  test('sources persist origin identity and availability independently', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);
    final source = LibrarySource(
      id: 'peer:server/library',
      kind: LibrarySourceKind.peer,
      displayName: 'Wohnzimmer-Server',
      libraryId: 'library',
      baseUrl: 'https://server.example',
      certificatePin: 'sha256:test',
      syncCursor: 42,
      availability: LibrarySourceAvailability.available,
      lastSeenAt: DateTime.utc(2026, 9, 4),
    );
    database.saveSource(source);
    expect(database.loadSource(source.id)?.displayName, 'Wohnzimmer-Server');
    expect(database.loadSource(source.id)?.syncCursor, 42);
    database.updateSourceStatus(
      source.id,
      availability: LibrarySourceAvailability.unreachable,
      syncCursor: 43,
    );
    final updated = database.loadSource(source.id)!;
    expect(updated.availability, LibrarySourceAvailability.unreachable);
    expect(updated.syncCursor, 43);
    expect(database.listSources(), hasLength(1));
  });

  test('sync journal is durable, ordered and idempotent', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);

    final first = database.appendSyncChange(
      entity: 'note',
      entityId: 'work-1',
      operation: 'upsert',
      payload: {'markdown': 'Notiz'},
      revision: 1,
      deviceId: 'phone-1',
      operationId: 'op-1',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    final retry = database.appendSyncChange(
      entity: 'note',
      entityId: 'work-1',
      operation: 'upsert',
      payload: {'markdown': 'andere Fassung'},
      revision: 99,
      deviceId: 'tablet-1',
      operationId: 'op-1',
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final second = database.appendSyncChange(
      entity: 'bookmark',
      entityId: 'bookmark-1',
      operation: 'delete',
      payload: const {},
      revision: 2,
      deviceId: 'phone-1',
      operationId: 'op-2',
    );

    expect(retry.sequence, first.sequence);
    expect(retry.payload, {'markdown': 'Notiz'});
    expect(database.syncJournalCursor, second.sequence);
    final page = database.listSyncChanges(since: 0, limit: 1);
    expect(page, hasLength(1));
    expect(page.single.operationId, first.operationId);
    expect(page.single.payload, first.payload);
    final tail = database.listSyncChanges(since: first.sequence);
    expect(tail, hasLength(1));
    expect(tail.single.operationId, second.operationId);
    expect(database.hasSyncOperation('op-2'), isTrue);
  });

  test('collections persist names, rules and ordered work references', () {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);
    final collection = database.saveCollection(
      name: 'Star Wars',
      kind: 'manual',
      rules: {'genre': 'Science Fiction'},
    );
    expect(collection.revision, 1);
    expect(database.listCollections().single.name, 'Star Wars');
    expect(database.loadCollection(collection.id)?.rules, {
      'genre': 'Science Fiction',
    });
    final renamed = database.saveCollection(
      collectionId: collection.id,
      name: 'Star Wars Collection',
      workIds: const [],
    );
    expect(renamed.id, collection.id);
    expect(renamed.revision, 2);
    expect(
      database.loadCollection(collection.id)?.name,
      'Star Wars Collection',
    );
    database.deleteCollection(collection.id);
    expect(database.listCollections(), isEmpty);
  });

  test('schema v1 is migrated to idempotent progress operations', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v1-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('''
      CREATE TABLE progress_revisions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        work_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        revision INTEGER NOT NULL,
        snapshot_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE (work_id, user_id, revision)
      )
    ''');
    legacy.execute('''
      CREATE TABLE works (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL
      )
    ''');
    legacy.userVersion = 1;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.columnExists('progress_revisions', 'operation_id'), isTrue);
    expect(migrated.columnExists('works', 'generated_cover_path'), isTrue);
  });

  test('schema v4 is migrated with portable audio properties', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v4-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('CREATE TABLE files (id TEXT PRIMARY KEY)');
    legacy.userVersion = 4;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.columnExists('files', 'container'), isTrue);
    expect(migrated.columnExists('files', 'audio_codec'), isTrue);
    expect(migrated.columnExists('files', 'codec_profile'), isTrue);
    expect(migrated.columnExists('files', 'audio_channels'), isTrue);
    expect(migrated.columnExists('files', 'sample_rate_hz'), isTrue);
  });

  test('schema v5 is migrated with stable publication anchors', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v5-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('''
      CREATE TABLE progress (
        work_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        position_kind TEXT NOT NULL,
        PRIMARY KEY (work_id, user_id)
      )
    ''');
    legacy.userVersion = 5;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(
      migrated.columnExists('progress', 'position_schema_version'),
      isTrue,
    );
    expect(migrated.columnExists('progress', 'chapter_id'), isTrue);
    expect(migrated.columnExists('progress', 'element_id'), isTrue);
    expect(migrated.columnExists('progress', 'scroll_offset'), isTrue);
  });

  test('schema v6 is migrated with persisted video episode identity', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v6-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('CREATE TABLE files (id TEXT PRIMARY KEY)');
    legacy.userVersion = 6;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.columnExists('files', 'video_episode_json'), isTrue);
  });

  test('schema v7 is migrated with collection revisions', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-db-v7-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/index.db');
    final legacy = sqlite3.open(file.path);
    legacy.execute('''
      CREATE TABLE collections (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        parent_id TEXT,
        kind TEXT NOT NULL DEFAULT 'manual',
        rules_json TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
    legacy.execute('''
      INSERT INTO collections (id, name, created_at)
      VALUES ('collection-1', 'Legacy', 1234)
    ''');
    legacy.execute('''
      CREATE TABLE collection_works (
        collection_id TEXT NOT NULL,
        work_id TEXT NOT NULL,
        position INTEGER NOT NULL DEFAULT 0
      )
    ''');
    legacy.userVersion = 7;
    legacy.close();

    final migrated = FundusDatabase.openFile(file);
    addTearDown(migrated.close);
    expect(migrated.userVersion, FundusDatabase.schemaVersion);
    expect(migrated.columnExists('collections', 'revision'), isTrue);
    expect(migrated.columnExists('collections', 'updated_at'), isTrue);
    expect(migrated.loadCollection('collection-1')?.revision, 1);
    expect(
      migrated.loadCollection('collection-1')?.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(1234),
    );
  });
}
