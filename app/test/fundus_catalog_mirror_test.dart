import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/fundus_catalog_mirror.dart';
import 'package:fundus/library/fundus_library_catalog.dart';
import 'package:fundus_core/fundus_core.dart';

FundusCatalogEntry _entry(
  String sourceId,
  String workId, {
  FundusCatalogAvailability availability = FundusCatalogAvailability.available,
}) {
  final source = FundusCatalogSource(
    id: sourceId,
    kind: sourceId.startsWith('remote:')
        ? FundusCatalogSourceKind.remote
        : FundusCatalogSourceKind.local,
    displayName: sourceId,
    availability: availability,
  );
  return FundusCatalogEntry(
    source: source,
    work: LibraryWorkSummary(
      id: workId,
      kind: 'webnovel',
      title: 'Titel $workId',
      author: 'Autor',
      authors: const ['Autor'],
      fileCount: 2,
      addedAt: DateTime.utc(2026, 9, 4),
      contentStyle: 'anime',
      tags: const ['fantasy'],
      mediaProgress: const MediaPosition(
        kind: MediaPositionKind.epubCfi,
        key: 'epubcfi(/6/4!)',
        scrollOffset: .25,
      ),
      providerMetadata: const {'anilist_id': 42},
      sourceId: sourceId,
      availability: availability.name,
    ),
  );
}

void main() {
  test('mirror round-trips source identity and publication metadata', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-mirror-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FundusCatalogMirrorStore(
      file: File('${directory.path}/catalog.db'),
    );

    await store.replaceAll([
      _entry('remote:server/library', 'work-1'),
      _entry('vault:local', 'work-2'),
    ]);

    final loaded = await store.load();
    expect(loaded, hasLength(2));
    final remote = loaded.singleWhere((entry) => entry.work.id == 'work-1');
    expect(remote.source.id, 'remote:server/library');
    expect(remote.source.isRemote, isTrue);
    expect(remote.work.mediaProgress?.key, 'epubcfi(/6/4!)');
    expect(remote.work.providerMetadata['anilist_id'], 42);
  });

  test('replaceSource is atomic and does not remove other sources', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-mirror-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FundusCatalogMirrorStore(
      file: File('${directory.path}/catalog.db'),
    );
    await store.replaceAll([
      _entry('remote:a/library', 'old'),
      _entry('remote:b/library', 'keep'),
    ]);

    await store.replaceSource('remote:a/library', [
      _entry('remote:a/library', 'new'),
    ]);
    final loaded = await store.load();
    expect(
      loaded.map((entry) => entry.work.id),
      containsAll(<String>['new', 'keep']),
    );
    expect(loaded.map((entry) => entry.work.id), isNot(contains('old')));
  });

  test(
    'unreachable source remains visible with its last known metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp('fundus-mirror-');
      addTearDown(() => directory.delete(recursive: true));
      final store = FundusCatalogMirrorStore(
        file: File('${directory.path}/catalog.db'),
      );
      await store.replaceSource('remote:server/library', [
        _entry(
          'remote:server/library',
          'work-1',
          availability: FundusCatalogAvailability.unreachable,
        ),
      ]);
      final loaded = await store.load();
      expect(
        loaded.single.source.availability,
        FundusCatalogAvailability.unreachable,
      );
      expect(loaded.single.work.title, 'Titel work-1');
    },
  );
}
