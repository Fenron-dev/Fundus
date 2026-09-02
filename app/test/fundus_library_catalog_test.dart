import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus/library/fundus_library_catalog.dart';

LibraryWorkSummary _work(String id, {bool offline = false}) =>
    LibraryWorkSummary(
      id: id,
      kind: 'manga',
      title: id,
      author: '',
      fileCount: 1,
      addedAt: DateTime(2026),
      offline: offline,
    );

void main() {
  test('catalog keeps source identity separate from work id', () {
    final local = FundusCatalogEntry(
      work: _work('work-1'),
      source: FundusLibraryCatalog.localSource('Vault'),
    );
    final remote = FundusCatalogEntry(
      work: _work('work-1'),
      source: FundusLibraryCatalog.remoteSource(
        serverId: 'server-a',
        libraryId: 'vault',
        displayName: 'Wohnzimmer-Mac',
      ),
    );

    final catalog = FundusLibraryCatalog([local, remote]);

    expect(catalog.entries, hasLength(2));
    expect(local.key, isNot(remote.key));
    expect(catalog.byKey(remote.key)?.source.displayName, 'Wohnzimmer-Mac');
  });

  test('offline source wins when the same source entry is merged', () {
    final online = FundusCatalogEntry(
      work: _work('work-1'),
      source: FundusLibraryCatalog.remoteSource(
        serverId: 'server-a',
        libraryId: 'vault',
        displayName: 'Mac',
      ),
    );
    final offline = FundusCatalogEntry(
      work: _work('work-1', offline: true),
      source: FundusLibraryCatalog.remoteSource(
        serverId: 'server-a',
        libraryId: 'vault',
        displayName: 'Mac',
        availability: FundusCatalogAvailability.offline,
      ),
    );

    final catalog = FundusLibraryCatalog([online, offline]);

    expect(catalog.entries, hasLength(1));
    expect(catalog.entries.single.work.offline, isTrue);
  });
}
