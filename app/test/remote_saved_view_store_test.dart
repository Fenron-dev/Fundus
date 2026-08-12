import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/remote_saved_view_store.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('remote saved views stay scoped to server and library', () async {
    final root = await Directory.systemTemp.createTemp('fundus-remote-views-');
    addTearDown(() => root.delete(recursive: true));
    final store = RemoteSavedViewStore(file: File('${root.path}/views.json'));

    await store.save(
      'server-a',
      'library-1',
      'Begonnen',
      const LibraryWorkQuery(
        progress: LibraryProgressFilter.inProgress,
        languages: {'de'},
      ),
    );
    await store.save(
      'server-b',
      'library-1',
      'Offline',
      const LibraryWorkQuery(offlineOnly: true),
    );

    final first = await store.load('server-a', 'library-1');
    final second = await store.load('server-b', 'library-1');
    expect(first.single.name, 'Begonnen');
    expect(first.single.query.progress, LibraryProgressFilter.inProgress);
    expect(first.single.query.languages, {'de'});
    expect(second.single.name, 'Offline');
    expect(second.single.query.offlineOnly, isTrue);

    expect(
      await store.delete('server-a', 'library-1', first.single.id),
      isEmpty,
    );
    expect(await store.load('server-b', 'library-1'), hasLength(1));
  });
}
