import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_peer_server_controller.dart';
import 'package:fundus/server/peer_server_identity_store.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test(
    'shares several libraries independently of the visible library',
    () async {
      final temporary = await Directory.systemTemp.createTemp('fundus-peer-');
      addTearDown(() => temporary.delete(recursive: true));
      final first = await _library(
        Directory('${temporary.path}/Erste Bibliothek'),
        'Erstes Werk',
      );
      final second = await _library(
        Directory('${temporary.path}/Zweite Bibliothek'),
        'Zweites Werk',
      );
      first.close();
      second.close();
      final controller = FundusPeerServerController(
        serverId: 'app-server-test',
        token: 'local-test-token',
      );
      addTearDown(controller.dispose);

      await controller.setSources([
        PeerLibrarySource(path: first.root.path, name: 'Erste'),
        PeerLibrarySource(path: second.root.path, name: 'Zweite'),
      ]);
      await controller.start();

      expect(controller.state, PeerServerState.running);
      expect(controller.libraries, hasLength(2));
      expect(controller.libraries.every((entry) => entry.available), isTrue);
      await controller.setLibraryShared(second.root.path, false);
      expect(controller.state, PeerServerState.running);
      expect(
        controller.libraries
            .singleWhere((entry) => entry.name == 'Zweite')
            .shared,
        isFalse,
      );
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        controller.localUri!.resolve('/v1/health'),
      );
      final response = await request.close();
      final body = jsonDecode(await utf8.decoder.bind(response).join()) as Map;
      expect(response.statusCode, 200);
      expect(body['server_id'], 'app-server-test');
      expect(body['server_id'], 'app-server-test');
      expect(body.containsKey('library_count'), isFalse);

      await controller.stop();
      expect(controller.state, PeerServerState.stopped);
    },
  );

  test(
    'keeps an unavailable library visible instead of failing the server',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'fundus-peer-missing-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final available = await _library(
        Directory('${temporary.path}/Verfügbar'),
        'Werk',
      );
      available.close();
      final controller = FundusPeerServerController(
        serverId: 'app-server-test',
        token: 'local-test-token',
      );
      addTearDown(controller.dispose);
      await controller.setSources([
        PeerLibrarySource(path: available.root.path, name: 'Verfügbar'),
        PeerLibrarySource(
          path: '${temporary.path}/Fehlt',
          name: 'Nicht verfügbar',
        ),
      ]);

      await controller.start();

      expect(controller.state, PeerServerState.running);
      expect(controller.libraries, hasLength(2));
      expect(
        controller.libraries
            .singleWhere((entry) => entry.name == 'Nicht verfügbar')
            .available,
        isFalse,
      );
      await controller.stop();
    },
  );

  test('restores the requested running state after an app restart', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'fundus-peer-autostart-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final library = await _library(
      Directory('${temporary.path}/Bibliothek'),
      'Werk',
    );
    library.close();
    final identityStore = PeerServerIdentityStore(
      Directory('${temporary.path}/identity'),
    );
    await identityStore.savePreferences(
      const PeerServerPreferences(autoStart: true),
    );
    final controller = FundusPeerServerController(
      identityStore: identityStore,
      token: 'local-test-token',
    );
    addTearDown(controller.dispose);
    await controller.setSources([
      PeerLibrarySource(path: library.root.path, name: 'Bibliothek'),
    ]);

    await controller.initialize();

    expect(controller.state, PeerServerState.running);
    await controller.stop();
    expect((await identityStore.loadPreferences()).autoStart, isFalse);
  });
}

Future<FundusLibrary> _library(Directory root, String title) async {
  final directory = Directory(
    '${root.path}/Audiobooks/Autor/Serie/01 - $title',
  );
  await directory.create(recursive: true);
  await File('${directory.path}/$title.mp3').writeAsBytes([1, 2, 3]);
  final library = await FundusLibrary.create(root);
  await library.index().drain<void>();
  return library;
}
