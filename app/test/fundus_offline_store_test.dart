import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_offline_store.dart';
import 'package:fundus/server/fundus_remote_client.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test(
    'server acknowledgement replaces only an explicitly discarded pending position',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-offline-progress-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = FundusOfflineStore(root: root);
      const local = MediaPosition(
        kind: MediaPositionKind.imageIndex,
        numericValue: 4,
        fileId: 'chapter-1',
      );
      const remote = MediaPosition(
        kind: MediaPositionKind.imageIndex,
        numericValue: 12,
        fileId: 'chapter-1',
      );
      await store.saveMediaProgress(
        serverId: 'server',
        libraryId: 'library',
        workId: 'manga',
        fileId: 'chapter-1',
        position: local,
        finished: false,
      );
      const serverProgress = FundusRemoteProgress(
        fileId: 'chapter-1',
        position: Duration.zero,
        mediaPosition: remote,
        finished: false,
        revision: 7,
        deviceId: 'tablet',
        deviceName: 'Tablet',
      );

      await store.cacheProgress(
        serverId: 'server',
        libraryId: 'library',
        workId: 'manga',
        progress: serverProgress,
      );
      expect(
        (await store.loadProgress(
          serverId: 'server',
          libraryId: 'library',
          workId: 'manga',
        ))?.mediaPosition?.numericValue,
        4,
      );

      await store.cacheProgress(
        serverId: 'server',
        libraryId: 'library',
        workId: 'manga',
        progress: serverProgress,
        replacePending: true,
      );
      final accepted = await store.loadProgress(
        serverId: 'server',
        libraryId: 'library',
        workId: 'manga',
      );
      expect(accepted?.mediaPosition?.numericValue, 12);
      expect(accepted?.pendingSync, isFalse);
      expect(accepted?.revision, 7);
      expect(accepted?.deviceName, 'Tablet');
    },
  );

  test(
    'remote EPUB annotations remain available in the offline store',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-offline-annotations-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = FundusOfflineStore(root: root);
      const position = MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 4,
        total: 12,
        fileId: 'novel.epub',
        chapterId: 'chapter-4',
        elementId: 'paragraph-7',
        scrollOffset: .42,
      );

      var annotations = await store.addMediaBookmark(
        serverId: 'server',
        libraryId: 'library',
        workId: 'novel',
        fileId: 'novel.epub',
        position: position,
        label: 'Wichtige Stelle',
      );
      annotations = await store.addTextHighlight(
        serverId: 'server',
        libraryId: 'library',
        workId: 'novel',
        fileId: 'novel.epub',
        position: position,
        quote: 'Ein markierter Satz.',
        color: '#90CAF9',
        note: 'Später prüfen',
      );
      annotations = await store.saveWorkNote(
        serverId: 'server',
        libraryId: 'library',
        workId: 'novel',
        markdown: '**Portable Notiz**',
      );
      annotations = await store.replaceWorkTags(
        serverId: 'server',
        libraryId: 'library',
        workId: 'novel',
        tags: const ['Fantasy', 'Favorit'],
      );

      expect(annotations.bookmarks.single.label, 'Wichtige Stelle');
      expect(annotations.highlights.single.quote, 'Ein markierter Satz.');
      final reopened = FundusOfflineStore(root: root);
      final restored = await reopened.loadAnnotations(
        serverId: 'server',
        libraryId: 'library',
        workId: 'novel',
      );
      expect(restored.bookmarks.single.mediaPosition.elementId, 'paragraph-7');
      expect(restored.highlights.single.mediaPosition.scrollOffset, .42);
      expect(restored.highlights.single.note, 'Später prüfen');
      expect(restored.notes.single.markdown, '**Portable Notiz**');
      expect(restored.tags, containsAll(['Fantasy', 'Favorit']));

      final cleaned = await reopened.deleteAnnotation(
        serverId: 'server',
        libraryId: 'library',
        workId: 'novel',
        annotationId: restored.bookmarks.single.id,
      );
      expect(cleaned.bookmarks, isEmpty);
      expect(cleaned.highlights, hasLength(1));
    },
  );

  test(
    'portable store includes fallback downloads and keeps incomplete works',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'fundus-offline-fallback-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final portableRoot = Directory('${temporary.path}/portable');
      final deviceRoot = Directory('${temporary.path}/device');
      const serverId = 'server-1';
      const libraryId = 'library-1';
      const workId = 'manga-1';
      final key = sha256
          .convert(utf8.encode('$serverId\u0000$libraryId\u0000$workId'))
          .toString();
      final workDirectory = Directory('${deviceRoot.path}/$key');
      await workDirectory.create(recursive: true);
      await File('${workDirectory.path}/0000.cbz').writeAsBytes([1, 2, 3]);
      await File('${workDirectory.path}/manifest.json').writeAsString(
        jsonEncode({
          'version': 1,
          'server_id': serverId,
          'library_id': libraryId,
          'work_id': workId,
          'title': 'Test-Manga',
          'kind': 'manga',
          'authors': ['Autor'],
          'downloaded_at': DateTime.utc(2026).toIso8601String(),
          'tracks': [
            {
              'id': 'chapter-1',
              'title': 'Kapitel 1.cbz',
              'path': '0000.cbz',
              'position': 0,
            },
            {
              'id': 'chapter-2',
              'title': 'Kapitel 2.cbz',
              'path': '0001.cbz',
              'position': 1,
            },
          ],
        }),
      );
      final deviceStore = FundusOfflineStore(root: deviceRoot);
      final portableStore = FundusOfflineStore(
        root: portableRoot,
        fallbacks: [deviceStore],
      );

      final work = (await portableStore.listAll()).single;
      expect(work.title, 'Test-Manga');
      expect(work.sourceServerName, isNull);
      expect(work.sourceLibraryName, isNull);
      expect(work.tracks.map((track) => track.id), ['chapter-1']);
      expect(work.incomplete, isTrue);
      expect(work.missingTrackTitles, ['Kapitel 2.cbz']);

      final labeled = await portableStore.updateSourceLabels(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        serverName: 'Arbeits-PC',
        libraryName: 'Comics',
      );
      expect(labeled?.sourceServerName, 'Arbeits-PC');
      expect(labeled?.sourceLibraryName, 'Comics');

      await portableStore.saveMediaProgress(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        fileId: 'chapter-1',
        position: const MediaPosition(
          kind: MediaPositionKind.imageIndex,
          numericValue: 8,
          total: 15,
          fileId: 'chapter-1',
        ),
        finished: false,
      );
      final progress = await deviceStore.loadProgress(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
      );
      expect(progress?.mediaPosition?.numericValue, 8);
      expect(await portableStore.pendingProgress(), hasLength(1));

      await portableStore.saveReaderProfile(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        deviceKey: 'android',
        readerKind: 'comic',
        profile: const {'layout': 'webtoon', 'page_scale': 'fitWidth'},
      );
      final profileBeforeAdoption = await deviceStore.loadReaderProfile(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        deviceKey: 'android',
        readerKind: 'comic',
      );
      expect(profileBeforeAdoption?['layout'], 'webtoon');
      expect(profileBeforeAdoption?['page_scale'], 'fitWidth');

      expect(await portableStore.adoptFallbackDownloads(), 1);
      await deviceRoot.delete(recursive: true);
      final adopted = (await portableStore.listAll()).single;
      expect(adopted.title, 'Test-Manga');
      expect(adopted.progress?.mediaPosition?.numericValue, 8);
      final profileAfterAdoption = await portableStore.loadReaderProfile(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        deviceKey: 'android',
        readerKind: 'comic',
      );
      expect(profileAfterAdoption, profileBeforeAdoption);
      expect(
        await File('${portableRoot.path}/$key/manifest.json').exists(),
        isTrue,
      );
    },
  );
}
