import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_offline_store.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
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
          'server_name': 'Arbeits-PC',
          'library_id': libraryId,
          'library_name': 'Comics',
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
      expect(work.sourceServerName, 'Arbeits-PC');
      expect(work.sourceLibraryName, 'Comics');
      expect(work.tracks.map((track) => track.id), ['chapter-1']);
      expect(work.incomplete, isTrue);
      expect(work.missingTrackTitles, ['Kapitel 2.cbz']);

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

      expect(await portableStore.adoptFallbackDownloads(), 1);
      await deviceRoot.delete(recursive: true);
      final adopted = (await portableStore.listAll()).single;
      expect(adopted.title, 'Test-Manga');
      expect(adopted.progress?.mediaPosition?.numericValue, 8);
      expect(
        await File('${portableRoot.path}/$key/manifest.json').exists(),
        isTrue,
      );
    },
  );
}
