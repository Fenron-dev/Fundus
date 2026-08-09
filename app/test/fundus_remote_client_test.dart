import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_client.dart';
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

    expect(profile.token, isNotEmpty);
    expect(libraries.single.name, 'Testbibliothek');
    expect(libraries.single.workCount, 1);
  });
}
