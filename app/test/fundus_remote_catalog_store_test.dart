import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
