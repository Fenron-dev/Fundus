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
}
