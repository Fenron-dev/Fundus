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

    await store.saveDeviceName(first.serverId, 'Arbeits-Laptop');
    final renamed = await store.loadOrCreate();
    expect(renamed.deviceName, 'Arbeits-Laptop');
    expect(renamed.serverId, first.serverId);
    expect(renamed.certificateFingerprint, first.certificateFingerprint);
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

  test('persists non-secret server startup preferences', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'fundus-peer-preferences-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = PeerServerIdentityStore(temporary);

    expect((await store.loadPreferences()).autoStart, isFalse);
    await store.savePreferences(
      const PeerServerPreferences(lanEnabled: true, autoStart: true),
    );

    final loaded = await store.loadPreferences();
    expect(loaded.lanEnabled, isTrue);
    expect(loaded.autoStart, isTrue);
    final source = await File(
      '${temporary.path}/server-preferences.json',
    ).readAsString();
    expect(source, isNot(contains('token')));
    expect(source, isNot(contains('certificate')));
  });
}
