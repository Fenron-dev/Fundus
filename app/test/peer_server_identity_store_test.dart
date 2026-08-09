import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/peer_server_identity_store.dart';
import 'package:fundus_server/fundus_server.dart';

void main() {
  test('keeps server identity and certificate stable', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'fundus-peer-identity-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = PeerServerIdentityStore(temporary);

    final first = await store.loadOrCreate();
    final second = await store.loadOrCreate();

    expect(second.serverId, first.serverId);
    expect(second.certificateFingerprint, first.certificateFingerprint);
    expect(second.privateKeyPem, first.privateKeyPem);
    expect(first.certificateFingerprint, hasLength(64));
  });

  test('persists token hashes without a raw device token', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'fundus-peer-devices-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = PeerServerIdentityStore(temporary);
    final device = FundusPairedDevice(
      id: 'phone-1',
      name: 'Telefon',
      tokenHash: FundusPairingAuthority.tokenDigest('raw-secret-token'),
      pairedAt: DateTime.utc(2026, 8, 9),
    );

    await store.savePairedDevices([device]);
    final source = await File(
      '${temporary.path}/paired-devices.json',
    ).readAsString();
    final loaded = await store.loadPairedDevices();

    expect(source, isNot(contains('raw-secret-token')));
    expect(loaded.single.tokenHash, device.tokenHash);
  });
}
