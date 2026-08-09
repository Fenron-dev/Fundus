import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/recent_library_store.dart';

void main() {
  test('keeps at most ten recent libraries with newest first', () async {
    final root = await Directory.systemTemp.createTemp('fundus-recents-');
    addTearDown(() => root.delete(recursive: true));
    final store = RecentLibraryStore(File('${root.path}/recent.json'));
    var entries = <RecentLibraryEntry>[];

    for (var index = 0; index < 12; index++) {
      entries = await store.remember('${root.path}/library-$index', entries);
    }

    final restored = await store.load();
    expect(restored, hasLength(10));
    expect(restored.first.path, '${root.path}/library-11');
    expect(restored.last.path, '${root.path}/library-2');
  });

  test('availability requires a Fundus manifest', () async {
    final root = await Directory.systemTemp.createTemp('fundus-recent-status-');
    addTearDown(() => root.delete(recursive: true));
    final entry = RecentLibraryEntry(
      path: root.path,
      lastOpenedAt: DateTime.now(),
    );

    expect(entry.available, isFalse);
    await Directory('${root.path}/.library').create();
    await File('${root.path}/.library/version.json').writeAsString('{}');
    expect(entry.available, isTrue);
  });

  test('persists and retains a macOS security bookmark', () async {
    final root = await Directory.systemTemp.createTemp('fundus-bookmark-');
    addTearDown(() => root.delete(recursive: true));
    final store = RecentLibraryStore(File('${root.path}/recent.json'));

    var entries = await store.remember(
      '${root.path}/library',
      const [],
      securityBookmark: 'opaque-bookmark-token',
    );
    entries = await store.remember('${root.path}/library', entries);
    final restored = await store.load();

    expect(entries.single.securityBookmark, 'opaque-bookmark-token');
    expect(restored.single.securityBookmark, 'opaque-bookmark-token');
  });
}
