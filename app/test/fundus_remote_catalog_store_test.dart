import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus/server/fundus_remote_catalog_store.dart';
import 'package:fundus/server/fundus_remote_client.dart';

void main() {
  test('remote catalog snapshots round-trip work metadata', () {
    final original = FundusRemoteCatalogSnapshot(
      serverId: 'server-1',
      libraryId: 'library-1',
      serverName: 'Wohnzimmer-Mac',
      libraryName: 'Anime',
      fetchedAt: DateTime.utc(2026, 9, 3, 12),
      etag: 'catalog-fingerprint-1',
      availability: LibrarySourceAvailability.unreachable,
      lastSeenAt: DateTime.utc(2026, 9, 3, 11, 59),
      works: [
        FundusRemoteWork(
          id: 'work-1',
          title: 'Chainsaw Man',
          authors: const ['Tatsuki Fujimoto'],
          hasCover: true,
          kind: 'video',
          fileCount: 12,
          publishedYear: 2022,
          progressPosition: const Duration(seconds: 42),
          progressDuration: const Duration(minutes: 24),
          progressFinished: false,
          tags: const ['Anime'],
          providerMetadata: const {
            'genres': ['Action'],
          },
        ),
      ],
    );

    final decoded = FundusRemoteCatalogSnapshot.fromJson(original.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.key, original.key);
    expect(decoded.serverName, 'Wohnzimmer-Mac');
    expect(decoded.libraryName, 'Anime');
    expect(decoded.etag, 'catalog-fingerprint-1');
    expect(decoded.availability, LibrarySourceAvailability.unreachable);
    expect(decoded.lastSeenAt, DateTime.utc(2026, 9, 3, 11, 59));
    expect(decoded.works.single.title, 'Chainsaw Man');
    expect(decoded.works.single.progressPosition, const Duration(seconds: 42));
    expect(decoded.works.single.providerMetadata['genres'], ['Action']);
  });

  test('invalid snapshots are ignored safely', () {
    expect(FundusRemoteCatalogSnapshot.fromJson(const {}), isNull);
    expect(FundusRemoteWork.fromJson(const {}), isNull);
  });

  test('catalog store persists source metadata and works in SQLite', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-catalog-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FundusRemoteCatalogStore(
      file: File('${directory.path}/remote-catalog.db'),
    );
    final snapshot = FundusRemoteCatalogSnapshot(
      serverId: 'server-1',
      libraryId: 'library-1',
      serverName: 'Mac',
      libraryName: 'Anime',
      fetchedAt: DateTime.utc(2026, 9, 4, 12),
      etag: 'etag-1',
      availability: LibrarySourceAvailability.offline,
      lastSeenAt: DateTime.utc(2026, 9, 4, 11),
      works: [
        FundusRemoteWork(
          id: 'work-1',
          title: 'Chainsaw Man',
          authors: const [],
          hasCover: false,
          kind: 'video',
          fileCount: 1,
        ),
      ],
    );

    await store.save([snapshot]);
    expect(await File('${directory.path}/remote-catalog.db').exists(), isTrue);
    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.key, snapshot.key);
    expect(loaded.single.etag, 'etag-1');
    expect(loaded.single.availability, LibrarySourceAvailability.offline);
    expect(loaded.single.lastSeenAt, DateTime.utc(2026, 9, 4, 11).toLocal());
    expect(loaded.single.works.single.title, 'Chainsaw Man');
  });

  test('legacy JSON cache is migrated on first SQLite load', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-catalog-');
    addTearDown(() => directory.delete(recursive: true));
    final snapshot = FundusRemoteCatalogSnapshot(
      serverId: 'server-legacy',
      libraryId: 'library-legacy',
      serverName: 'Old Mac',
      libraryName: 'Books',
      fetchedAt: DateTime.utc(2026, 9, 4),
      works: const [],
    );
    final legacy = File('${directory.path}/remote-catalog.json');
    await legacy.writeAsString('[${jsonEncode(snapshot.toJson())}]');
    final store = FundusRemoteCatalogStore(
      file: File('${directory.path}/remote-catalog.db'),
    );

    final loaded = await store.load();
    expect(loaded.single.serverId, 'server-legacy');
    expect(await File('${directory.path}/remote-catalog.db').exists(), isTrue);
  });

  test('upsertSource replaces only the selected source', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-catalog-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FundusRemoteCatalogStore(
      file: File('${directory.path}/remote-catalog.db'),
    );
    FundusRemoteCatalogSnapshot source(
      String serverId,
      String libraryId,
      String title,
    ) => FundusRemoteCatalogSnapshot(
      serverId: serverId,
      libraryId: libraryId,
      serverName: serverId,
      libraryName: libraryId,
      fetchedAt: DateTime.utc(2026, 9, 4),
      works: [
        FundusRemoteWork(
          id: '$serverId-work',
          title: title,
          authors: const [],
          hasCover: false,
          kind: 'video',
          fileCount: 1,
        ),
      ],
    );

    await store.save([source('server-a', 'library-a', 'A1')]);
    await store.upsertSource(source('server-a', 'library-a', 'A2'));
    await store.upsertSource(source('server-b', 'library-b', 'B1'));

    final loaded = await store.load();
    expect(loaded, hasLength(2));
    expect(
      loaded
          .singleWhere((item) => item.serverId == 'server-a')
          .works
          .single
          .title,
      'A2',
    );
    expect(
      loaded
          .singleWhere((item) => item.serverId == 'server-b')
          .works
          .single
          .title,
      'B1',
    );
  });

  test(
    'progress journal entries update the cached summary and cursor persists',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fundus-catalog-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = FundusRemoteCatalogStore(
        file: File('${directory.path}/remote-catalog.db'),
      );
      await store.save([
        FundusRemoteCatalogSnapshot(
          serverId: 'server-1',
          libraryId: 'library-1',
          serverName: 'Mac',
          libraryName: 'Anime',
          fetchedAt: DateTime.utc(2026, 9, 4),
          works: [
            FundusRemoteWork(
              id: 'work-1',
              title: 'Episode',
              authors: const [],
              hasCover: false,
              kind: 'video',
              fileCount: 1,
            ),
          ],
        ),
      ]);
      final changed = await store.applySyncProgress('server-1', 'library-1', [
        LibrarySyncJournalEntry(
          sequence: 7,
          entity: 'progress',
          entityId: 'work-1/default',
          operation: 'upsert',
          payload: {
            'work_id': 'work-1',
            'position': {'numeric_value': 42.5, 'total': 120.0},
            'finished': false,
          },
          revision: 2,
          deviceId: 'tablet',
          operationId: 'op-7',
          createdAt: DateTime.utc(2026, 9, 4, 12),
        ),
      ]);
      expect(
        changed!.works.single.progressPosition,
        const Duration(milliseconds: 42500),
      );
      expect(
        changed.works.single.progressDuration,
        const Duration(seconds: 120),
      );
      await store.saveSyncCursor('server-1', 'library-1', 7);
      expect(await store.loadSyncCursor('server-1', 'library-1'), 7);
    },
  );

  test('catalog journal entries update and remove cached works', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fundus-catalog-delta-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = FundusRemoteCatalogStore(
      file: File('${directory.path}/remote-catalog.db'),
    );
    await store.save([
      FundusRemoteCatalogSnapshot(
        serverId: 'server-1',
        libraryId: 'library-1',
        serverName: 'Mac',
        libraryName: 'Anime',
        fetchedAt: DateTime.utc(2026, 9, 4),
        works: [
          FundusRemoteWork(
            id: 'work-1',
            title: 'Alte Folge',
            authors: const [],
            hasCover: false,
            kind: 'video',
            fileCount: 1,
          ),
        ],
      ),
    ]);
    final replacement = FundusRemoteWork(
      id: 'work-2',
      title: 'Neue Folge',
      authors: const [],
      hasCover: false,
      kind: 'video',
      fileCount: 1,
    );
    final added = await store.applySyncEntries('server-1', 'library-1', [
      LibrarySyncJournalEntry(
        sequence: 1,
        entity: 'catalog_work',
        entityId: replacement.id,
        operation: 'upsert',
        payload: {'work_id': replacement.id, 'work': replacement.toJson()},
        revision: 1,
        deviceId: 'server',
        operationId: 'catalog-upsert-1',
        createdAt: DateTime.utc(2026, 9, 4, 12),
      ),
    ]);
    expect(added!.works.map((work) => work.id), ['work-1', 'work-2']);
    final removed = await store.applySyncEntries('server-1', 'library-1', [
      LibrarySyncJournalEntry(
        sequence: 2,
        entity: 'catalog_work',
        entityId: 'work-1',
        operation: 'delete',
        payload: {'work_id': 'work-1'},
        revision: 1,
        deviceId: 'server',
        operationId: 'catalog-delete-1',
        createdAt: DateTime.utc(2026, 9, 4, 12, 1),
      ),
    ]);
    expect(removed!.works.map((work) => work.id), ['work-2']);
  });
}
