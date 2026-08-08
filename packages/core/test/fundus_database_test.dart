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
}
