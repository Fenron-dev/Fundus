import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import 'fundus_remote_client.dart';

const fundusPeerServiceType = '_fundus._tcp';

final class FundusPeerAdvertiser {
  BonsoirBroadcast? _broadcast;

  Future<void> start({
    required String deviceId,
    required String deviceName,
    required int port,
  }) async {
    await stop();
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: deviceName,
        type: fundusPeerServiceType,
        port: port,
        attributes: {
          'id': deviceId,
          'name': deviceName,
          'api': '1',
          'tls': '1',
        },
      ),
      printLogs: false,
    );
    try {
      await broadcast.initialize();
      await broadcast.start();
      _broadcast = broadcast;
    } catch (_) {
      try {
        await broadcast.stop();
      } catch (_) {
        // Die Plattform hat den Broadcast noch nicht vollständig gestartet.
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    final broadcast = _broadcast;
    _broadcast = null;
    if (broadcast != null) {
      try {
        await broadcast.stop();
      } catch (_) {
        // Der eigentliche Fundus-Server muss trotzdem beendet werden können.
      }
    }
  }
}

final class FundusDiscoveredPeer {
  const FundusDiscoveredPeer({
    required this.deviceId,
    required this.deviceName,
    required this.port,
    required this.addresses,
  });

  final String deviceId;
  final String deviceName;
  final int port;
  final List<String> addresses;
}

final class FundusPeerDiscovery {
  FundusPeerDiscovery({FundusRemoteClient client = const FundusRemoteClient()})
    : _client = client;

  final FundusRemoteClient _client;

  Future<List<FundusDiscoveredPeer>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final discovery = BonsoirDiscovery(
      type: fundusPeerServiceType,
      printLogs: false,
    );
    final peers = <String, FundusDiscoveredPeer>{};
    StreamSubscription<BonsoirDiscoveryEvent>? subscription;
    try {
      await discovery.initialize();
      subscription = discovery.eventStream!.listen((event) {
        switch (event) {
          case BonsoirDiscoveryServiceFoundEvent(:final service):
            service.resolve(discovery.serviceResolver);
          case BonsoirDiscoveryServiceResolvedEvent(:final service) ||
              BonsoirDiscoveryServiceUpdatedEvent(:final service):
            final id = service.attributes['id']?.trim();
            if (id == null || id.isEmpty || service.port <= 0) return;
            final addresses = service.hostAddresses
                .where(_usableAddress)
                .toSet()
                .toList(growable: false);
            if (addresses.isEmpty) return;
            peers[id] = FundusDiscoveredPeer(
              deviceId: id,
              deviceName: service.attributes['name'] ?? service.name,
              port: service.port,
              addresses: addresses,
            );
          default:
            break;
        }
      });
      await discovery.start();
      await Future<void>.delayed(timeout);
    } catch (_) {
      return const [];
    } finally {
      await subscription?.cancel();
      try {
        await discovery.stop();
      } catch (_) {
        // Discovery ist auf dieser Plattform bereits beendet.
      }
    }
    return peers.values.toList(growable: false);
  }

  Future<List<FundusRemoteServer>> relocate(
    List<FundusRemoteServer> servers, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (servers.isEmpty) return servers;
    final discovered = {
      for (final peer in await discover(timeout: timeout)) peer.deviceId: peer,
    };
    return Future.wait([
      for (final server in servers)
        () async {
          final peer = discovered[server.id];
          if (peer == null) return server;
          for (final address in peer.addresses) {
            final candidate = Uri(
              scheme: 'https',
              host: address,
              port: peer.port,
            );
            try {
              final verified = await _client.verifyEndpoint(server, candidate);
              return verified.copyWith(serverName: peer.deviceName);
            } catch (_) {
              // Nur ein TLS-gepinnter Endpunkt mit passender device_id gilt.
            }
          }
          return server;
        }(),
    ]);
  }

  static bool _usableAddress(String value) {
    final address = InternetAddress.tryParse(value);
    return address != null && !address.isLoopback && !address.isLinkLocal;
  }
}
