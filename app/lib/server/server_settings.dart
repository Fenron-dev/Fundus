import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'fundus_peer_server_controller.dart';
import 'fundus_offline_store.dart';
import 'remote_servers_view.dart';

Future<void> showFundusServerSettings(
  BuildContext context,
  FundusPeerServerController controller, {
  FundusOfflineStore? offlineStore,
}) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760),
      child: _ServerSettings(
        controller: controller,
        offlineStore: offlineStore,
      ),
    ),
  ),
);

class _ServerSettings extends StatelessWidget {
  const _ServerSettings({required this.controller, this.offlineStore});

  final FundusPeerServerController controller;
  final FundusOfflineStore? offlineStore;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) => Scaffold(
      appBar: AppBar(
        title: const Text('Server & Freigaben'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            onPressed: () => showFundusRemoteServers(
              context,
              peerServer: controller,
              offlineStore: offlineStore,
            ),
            tooltip: 'Mit Server verbinden',
            icon: const Icon(Icons.devices),
          ),
          IconButton(
            onPressed: () => Navigator.pop(context),
            tooltip: 'Schließen',
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('Name dieses Geräts'),
              subtitle: Text(controller.deviceName),
              trailing: IconButton(
                onPressed: controller.isBusy
                    ? null
                    : () => _renameOwnDevice(context),
                tooltip: 'Gerätenamen ändern',
                icon: const Icon(Icons.edit_outlined),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _statusCard(context),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            secondary: const Icon(Icons.lan_outlined),
            title: const Text('Im lokalen Netzwerk freigeben'),
            subtitle: const Text(
              'TLS-verschlüsselt; neue Geräte benötigen QR-Code und PIN.',
            ),
            value: controller.lanEnabled,
            onChanged: controller.isBusy ? null : controller.setLanEnabled,
          ),
          if (controller.lanEnabled && controller.isRunning) ...[
            const SizedBox(height: 12),
            _pairingCard(context),
          ],
          const SizedBox(height: 20),
          Text(
            'Freigegebene Bibliotheken',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (controller.libraries.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'Noch keine zuletzt verwendete Bibliothek verfügbar.',
                ),
              ),
            )
          else
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (
                    var index = 0;
                    index < controller.libraries.length;
                    index++
                  ) ...[
                    _libraryTile(context, controller.libraries[index]),
                    if (index < controller.libraries.length - 1)
                      const Divider(height: 1),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 18),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.shield_outlined),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Ohne LAN-Freigabe ist der Server nur auf diesem Gerät erreichbar. '
                      'Im LAN wird HTTPS mit einem gerätegebundenen Zertifikat verwendet. '
                      'Freigaben können unten jederzeit widerrufen werden.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _statusCard(BuildContext context) {
    final running = controller.isRunning;
    final color = switch (controller.state) {
      PeerServerState.running => Colors.green,
      PeerServerState.failed => Theme.of(context).colorScheme.error,
      PeerServerState.starting || PeerServerState.stopping => Colors.orange,
      PeerServerState.stopped => Theme.of(context).colorScheme.outline,
    };
    final label = switch (controller.state) {
      PeerServerState.running => 'Server läuft',
      PeerServerState.failed => 'Serverfehler',
      PeerServerState.starting => 'Server startet …',
      PeerServerState.stopping => 'Server stoppt …',
      PeerServerState.stopped => 'Server ist aus',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 13, color: color),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      controller.isBusy ||
                          (!running && !controller.hasSharedSources)
                      ? null
                      : running
                      ? controller.stop
                      : controller.start,
                  icon: Icon(running ? Icons.stop : Icons.play_arrow),
                  label: Text(running ? 'Stoppen' : 'Starten'),
                ),
              ],
            ),
            if (controller.localUri case final uri?) ...[
              const SizedBox(height: 10),
              SelectableText('${uri.host}:${uri.port}'),
            ],
            if (controller.error case final error?) ...[
              const SizedBox(height: 10),
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _pairingCard(BuildContext context) {
    final payload = controller.pairingPayload;
    final session = controller.pairingSession;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Gerät verbinden',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (session == null)
                  FilledButton.icon(
                    onPressed: controller.networkUris.isEmpty
                        ? null
                        : controller.beginPairing,
                    icon: const Icon(Icons.qr_code_2),
                    label: const Text('Pairing starten'),
                  )
                else
                  TextButton(
                    onPressed: controller.cancelPairing,
                    child: const Text('Abbrechen'),
                  ),
              ],
            ),
            if (controller.networkUris.isEmpty) ...[
              const SizedBox(height: 8),
              const Text('Keine verwendbare IPv4-Adresse im LAN gefunden.'),
            ] else ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<Uri>(
                initialValue: controller.selectedPairingUri,
                decoration: const InputDecoration(
                  labelText: 'Adresse für den QR-Code',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final uri in controller.networkUris)
                    DropdownMenuItem(value: uri, child: Text(uri.toString())),
                ],
                onChanged: session == null ? controller.setPairingUri : null,
              ),
            ],
            if (payload != null && session != null) ...[
              const SizedBox(height: 16),
              Center(
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.white),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      data: payload,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  session.pin,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    letterSpacing: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Center(
                child: Text(
                  'Gültig bis ${TimeOfDay.fromDateTime(session.expiresAt).format(context)} Uhr',
                ),
              ),
            ],
            if (controller.pairedDevices.isNotEmpty) ...[
              const Divider(height: 32),
              Text(
                'Berechtigte Geräte',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final device in controller.pairedDevices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices_other),
                  title: Text(device.name),
                  subtitle: Text(
                    'Verbunden am ${MaterialLocalizations.of(context).formatShortDate(device.pairedAt.toLocal())}',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        onPressed: () => _renamePairedDevice(
                          context,
                          device.id,
                          device.name,
                        ),
                        tooltip: 'Gerät benennen',
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        onPressed: () => controller.revokeDevice(device.id),
                        tooltip: 'Berechtigung widerrufen',
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _libraryTile(BuildContext context, PeerSharedLibraryStatus library) =>
      ListTile(
        leading: Icon(
          Icons.circle,
          size: 12,
          color: library.available
              ? Colors.green
              : Theme.of(context).colorScheme.error,
        ),
        title: Text(library.name),
        subtitle: Text(
          library.error ??
              (library.workCount == null
                  ? library.path
                  : '${library.workCount} Werk(e) · gleichzeitig freigegeben'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Switch(
          value: library.shared,
          onChanged: controller.isBusy
              ? null
              : (value) => controller.setLibraryShared(library.path, value),
        ),
      );

  Future<String?> _askName(
    BuildContext context,
    String title,
    String current,
  ) async {
    final text = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Gerätename',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    text.dispose();
    return result?.trim().isEmpty == true ? null : result;
  }

  Future<void> _renameOwnDevice(BuildContext context) async {
    final name = await _askName(
      context,
      'Dieses Gerät benennen',
      controller.deviceName,
    );
    if (name != null) await controller.setDeviceName(name);
  }

  Future<void> _renamePairedDevice(
    BuildContext context,
    String deviceId,
    String current,
  ) async {
    final name = await _askName(context, 'Verbundenes Gerät benennen', current);
    if (name != null) await controller.renamePairedDevice(deviceId, name);
  }
}
