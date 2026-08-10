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
    final detail = await client.work(
      profile,
      libraries.single.id,
      works.single,
    );
    final proxy = await FundusRemoteStreamProxy.start(
      server: profile,
      libraryId: libraries.single.id,
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
    expect(loaded?.fileId, detail.tracks.single.id);
    expect(loaded?.position, const Duration(seconds: 2));

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
    expect(transferredBytes, containsAllInOrder([0, 3]));
    expect(
      (await offlineStore.loadProgress(
        serverId: profile.id,
        libraryId: libraries.single.id,
        workId: works.single.id,
      ))?.position,
      const Duration(seconds: 2),
    );
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
