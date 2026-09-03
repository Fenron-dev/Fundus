import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_client.dart';
import 'package:fundus/server/fundus_peer_discovery.dart';
import 'package:fundus/server/fundus_remote_stream_proxy.dart';
import 'package:fundus/server/fundus_offline_store.dart';
import 'package:fundus/server/peer_server_identity_store.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

void main() {
  test('pairs over pinned TLS and browses a remote library', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'fundus-remote-client-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final media = Directory('${temporary.path}/media/Audiobooks/Autor/Buch');
    await media.create(recursive: true);
    await File('${media.path}/Buch.mp3').writeAsBytes([1, 2, 3]);
    await File('${media.path}/cover.jpg').writeAsBytes([4, 5, 6]);
    final library = await FundusLibrary.create(
      Directory('${temporary.path}/media'),
    );
    await library.index().drain<void>();
    final registry = FundusLibraryRegistry()
      ..register(library, name: 'Testbibliothek');
    addTearDown(registry.close);
    final authority = FundusPairingAuthority();
    final session = authority.begin();
    final identity = await PeerServerIdentityStore(
      Directory('${temporary.path}/identity'),
    ).loadOrCreate();
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(identity.certificatePem))
      ..usePrivateKeyBytes(utf8.encode(identity.privateKeyPem));
    final server = await shelf_io.serve(
      FundusServerHandler(
        token: 'loopback-test-token',
        serverId: identity.serverId,
        serverName: 'Test-Desktop',
        registry: registry,
        pairingAuthority: authority,
      ).handler,
      InternetAddress.loopbackIPv4,
      0,
      securityContext: context,
    );
    addTearDown(() => server.close(force: true));
    final invitation = FundusPairingInvitation(
      baseUri: Uri.parse('https://127.0.0.1:${server.port}'),
      serverId: identity.serverId,
      certificateFingerprint: identity.certificateFingerprint,
      nonce: session.nonce,
      pin: session.pin,
      expiresAt: session.expiresAt,
    );

    const client = FundusRemoteClient();
    final profile = await client.pair(
      invitation,
      deviceId: 'client-test',
      deviceName: 'Testgerät',
    );
    final libraries = await client.libraries(profile);
    final verified = await client.verifyEndpoint(profile, invitation.baseUri);

    expect(profile.token, isNotEmpty);
    expect(profile.name, 'Test-Desktop');
    expect(profile.serverName, 'Test-Desktop');
    expect(verified.id, profile.id);
    expect(verified.baseUri, invitation.baseUri);
    expect(libraries.single.name, 'Testbibliothek');
    expect(libraries.single.workCount, 1);

    final works = await client.works(profile, libraries.single.id);
    expect(works.single.kind, 'audiobook');
    final localWork = library.listWorks().single;
    library.saveCollection(
      name: 'Test-Sammlung',
      workIds: [localWork.id],
    );
    final collections = await client.collections(
      profile,
      libraries.single.id,
    );
    expect(collections.single.name, 'Test-Sammlung');
    expect(collections.single.workIds, [localWork.id]);
    final detail = await client.work(
      profile,
      libraries.single.id,
      works.single,
    );
    expect(detail.chapters, hasLength(1));
    expect(detail.chapters.single.fileId, detail.tracks.single.id);
    expect(detail.chapters.single.position, Duration.zero);
    final proxy = await FundusRemoteStreamProxy.start(
      server: profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      tracks: detail.tracks,
    );
    addTearDown(proxy.close);
    final httpClient = HttpClient();
    addTearDown(httpClient.close);
    final request = await httpClient.getUrl(proxy.urls.single);
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=1-2');
    final streamed = await request.close();
    expect(streamed.statusCode, HttpStatus.partialContent);
    expect(await streamed.expand((chunk) => chunk).toList(), [2, 3]);
    final coverRequest = await httpClient.getUrl(proxy.coverUrl);
    final coverResponse = await coverRequest.close();
    expect(coverResponse.statusCode, HttpStatus.ok);
    expect(await coverResponse.expand((chunk) => chunk).toList(), [4, 5, 6]);

    final saved = await client.saveProgress(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      fileId: detail.tracks.single.id,
      position: const Duration(seconds: 2),
      duration: const Duration(seconds: 3),
      finished: false,
      deviceId: 'client-test',
      operationId: 'remote-progress-test',
    );
    final loaded = await client.progress(
      profile,
      libraries.single.id,
      works.single.id,
    );
    expect(saved.position, const Duration(seconds: 2));
    expect(saved.duration, const Duration(seconds: 3));
    expect(loaded?.fileId, detail.tracks.single.id);
    expect(loaded?.position, const Duration(seconds: 2));
    expect(loaded?.duration, const Duration(seconds: 3));
    final history = await client.progressRevisions(
      profile,
      libraries.single.id,
      works.single.id,
    );
    expect(history.single.revision, 1);
    expect(history.single.deviceName, 'Testgerät');
    expect(history.single.duration, const Duration(seconds: 3));
    final restoredHistory = await client.restoreProgressRevision(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      revision: 1,
      deviceId: 'client-test',
      operationId: 'restore-remote-progress-test',
    );
    expect(restoredHistory.revision, 2);
    expect(restoredHistory.position, const Duration(seconds: 2));
    expect(restoredHistory.duration, const Duration(seconds: 3));

    final readerPosition = MediaPosition(
      kind: MediaPositionKind.imageIndex,
      numericValue: 7,
      total: 18,
      fileId: detail.tracks.single.id,
      chapterId: 'Kapitel 1',
      elementId: '007.webp',
      scrollOffset: .35,
      label: 'Seite 7',
    );
    final savedReader = await client.saveMediaProgress(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      fileId: detail.tracks.single.id,
      position: readerPosition,
      finished: false,
      deviceId: 'client-test',
      operationId: 'remote-reader-progress-test',
    );
    final loadedReader = await client.progress(
      profile,
      libraries.single.id,
      works.single.id,
    );
    expect(savedReader.mediaPosition?.kind, MediaPositionKind.imageIndex);
    expect(loadedReader?.mediaPosition?.numericValue, 7);
    expect(loadedReader?.mediaPosition?.elementId, '007.webp');
    expect(loadedReader?.mediaPosition?.scrollOffset, .35);
    final readerHistory = await client.progressRevisions(
      profile,
      libraries.single.id,
      works.single.id,
    );
    expect(
      readerHistory.first.mediaPosition.kind,
      MediaPositionKind.imageIndex,
    );
    expect(readerHistory.first.mediaPosition.elementId, '007.webp');
    expect(readerHistory.first.mediaPosition.scrollOffset, .35);
    final restoredReader = await client.restoreProgressRevision(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      revision: readerHistory.first.revision,
      deviceId: 'client-test',
      operationId: 'restore-remote-reader-progress-test',
    );
    expect(restoredReader.mediaPosition?.numericValue, 7);
    expect(restoredReader.mediaPosition?.scrollOffset, .35);

    final bookmarkAnnotations = await client.saveBookmark(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      fileId: detail.tracks.single.id,
      position: readerPosition,
      label: 'Remote-Lesezeichen',
    );
    expect(bookmarkAnnotations.bookmarks.single.label, 'Remote-Lesezeichen');
    final highlightAnnotations = await client.saveHighlight(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      fileId: detail.tracks.single.id,
      position: readerPosition,
      quote: 'Remote-Markierung',
      color: '#FFF176',
    );
    expect(highlightAnnotations.highlights.single.quote, 'Remote-Markierung');
    final loadedAnnotations = await client.annotations(
      profile,
      libraries.single.id,
      works.single.id,
    );
    expect(loadedAnnotations.bookmarks, hasLength(1));
    expect(loadedAnnotations.highlights, hasLength(1));
    final withoutBookmark = await client.deleteAnnotation(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      annotationId: loadedAnnotations.bookmarks.single.id,
      highlight: false,
    );
    expect(withoutBookmark.bookmarks, isEmpty);
    final withoutHighlight = await client.deleteAnnotation(
      profile,
      libraryId: libraries.single.id,
      workId: works.single.id,
      annotationId: loadedAnnotations.highlights.single.id,
      highlight: true,
    );
    expect(withoutHighlight.highlights, isEmpty);

    final queueSession = await client.savePlaybackSession(
      profile,
      libraryId: libraries.single.id,
      deviceId: 'client-test',
      expectedRevision: 0,
      session: PlaybackSession(
        id: 'ignored-client-id',
        items: [
          PlaybackSessionItem(
            workId: works.single.id,
            fileIds: [detail.tracks.single.id],
            position: 0,
          ),
        ],
        currentIndex: 0,
        currentPosition: MediaPosition(
          kind: MediaPositionKind.time,
          numericValue: 2,
          fileId: detail.tracks.single.id,
        ),
        repeatMode: RepeatMode.all,
        shuffleOrder: const [0],
      ),
    );
    expect(queueSession.revision, 1);
    expect(
      (await client.playbackSession(profile, libraries.single.id))?.repeatMode,
      RepeatMode.all,
    );
    await expectLater(
      client.savePlaybackSession(
        profile,
        libraryId: libraries.single.id,
        deviceId: 'stale-client',
        expectedRevision: 0,
        session: queueSession,
      ),
      throwsA(
        isA<FundusRemotePlaybackSessionConflict>().having(
          (error) => error.current?.revision,
          'current revision',
          1,
        ),
      ),
    );

    final playlist = await client.createPlaylist(
      profile,
      libraryId: libraries.single.id,
      name: 'Mobil hören',
      mediaType: 'audiobook',
      workIds: [works.single.id],
    );
    expect(playlist.revision, 1);
    expect(
      (await client.playlists(profile, libraries.single.id)).single.id,
      playlist.id,
    );
    final updatedPlaylist = await client.savePlaylist(
      profile,
      libraryId: libraries.single.id,
      playlist: playlist,
      name: 'Mobil hören – geändert',
      mediaType: 'audiobook',
      workIds: [works.single.id],
    );
    expect(updatedPlaylist.revision, 2);
    await expectLater(
      client.savePlaylist(
        profile,
        libraryId: libraries.single.id,
        playlist: playlist,
        name: 'Veraltete Änderung',
        mediaType: 'audiobook',
        workIds: [works.single.id],
      ),
      throwsA(
        isA<FundusRemotePlaylistConflict>().having(
          (error) => error.current.revision,
          'current revision',
          2,
        ),
      ),
    );
    await client.deletePlaylist(
      profile,
      libraryId: libraries.single.id,
      playlist: updatedPlaylist,
    );
    expect(await client.playlists(profile, libraries.single.id), isEmpty);

    final portableLibrary = Directory('${temporary.path}/portable-library');
    final offlineStore = FundusOfflineStore.forLibrary(portableLibrary);
    final transferredBytes = <int>[];
    final offline = await offlineStore.download(
      client,
      profile,
      libraries.single,
      works.single,
      onTransfer: (_, _, received, _) => transferredBytes.add(received),
    );
    expect(await File(offline.tracks.single.path).readAsBytes(), [1, 2, 3]);
    expect(offline.kind, 'audiobook');
    expect(offline.chapters, hasLength(1));
    expect(offline.chapters.single.fileId, offline.tracks.single.id);
    expect(transferredBytes, containsAllInOrder([0, 3]));
    final cachedReaderProgress = await offlineStore.loadProgress(
      serverId: profile.id,
      libraryId: libraries.single.id,
      workId: works.single.id,
    );
    expect(
      cachedReaderProgress?.mediaPosition?.kind,
      MediaPositionKind.imageIndex,
    );
    expect(cachedReaderProgress?.mediaPosition?.numericValue, 7);
    final refreshed = await offlineStore.refreshMetadata(
      serverId: profile.id,
      libraryId: libraries.single.id,
      work: FundusRemoteWork(
        id: works.single.id,
        title: works.single.title,
        authors: const ['Autorin'],
        hasCover: false,
        subtitle: 'Untertitel',
        series: 'Testserie',
        seriesSequence: 2,
        narrators: const ['Sprecher'],
        language: 'de',
        description: 'Beschreibung',
        publisher: 'Testverlag',
        publishedYear: 2026,
        fileCount: 1,
      ),
    );
    expect(refreshed?.subtitle, 'Untertitel');
    expect(refreshed?.narrators, ['Sprecher']);
    expect(refreshed?.language, 'de');
    expect(refreshed?.publisher, 'Testverlag');
    expect(refreshed?.publishedYear, 2026);
    expect(
      Directory('${portableLibrary.path}/_fundus/offline-media')
          .listSync(recursive: true)
          .whereType<File>()
          .any((file) => file.path.endsWith('.part')),
      isFalse,
    );
    final pending = await offlineStore.saveProgress(
      serverId: profile.id,
      libraryId: libraries.single.id,
      workId: works.single.id,
      fileId: detail.tracks.single.id,
      position: const Duration(seconds: 1),
      finished: false,
    );
    final offlineProgress = await offlineStore.loadProgress(
      serverId: profile.id,
      libraryId: libraries.single.id,
      workId: works.single.id,
    );
    expect(offlineProgress?.position, const Duration(seconds: 1));
    expect(
      (await offlineStore.pendingProgress()).single.operationId,
      pending.operationId,
    );
    await offlineStore.markProgressSynced(pending);
    expect(await offlineStore.pendingProgress(), isEmpty);
    expect((await offlineStore.listAll()).single.workId, works.single.id);
    await offlineStore.remove(
      serverId: profile.id,
      libraryId: libraries.single.id,
      workId: works.single.id,
    );
    expect(
      await offlineStore.lookup(
        serverId: profile.id,
        libraryId: libraries.single.id,
        workId: works.single.id,
      ),
      isNull,
    );
    final ledger = File(
      '${portableLibrary.path}/_fundus/offline-media/downloads.log',
    );
    expect(await ledger.exists(), isTrue);
    final ledgerText = await ledger.readAsString();
    expect(ledgerText, contains('"event":"downloaded"'));
    expect(ledgerText, contains('"event":"removed"'));

    await server.close(force: true);
    final relocatedServer = await shelf_io.serve(
      FundusServerHandler(
        token: 'loopback-test-token',
        serverId: identity.serverId,
        serverName: 'Test-Desktop',
        registry: registry,
        pairingAuthority: authority,
      ).handler,
      InternetAddress.loopbackIPv4,
      0,
      securityContext: context,
    );
    addTearDown(() => relocatedServer.close(force: true));
    final discovery = FundusPeerDiscovery(
      discoverer: (_) async => [
        FundusDiscoveredPeer(
          deviceId: identity.serverId,
          deviceName: 'Test-Desktop',
          port: relocatedServer.port,
          addresses: const ['127.0.0.1'],
        ),
      ],
    );
    final relocated = await discovery.resolve(profile);
    expect(relocated.id, profile.id);
    expect(relocated.baseUri.port, relocatedServer.port);
  });
}
