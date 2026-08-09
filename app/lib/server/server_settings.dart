import 'package:flutter/material.dart';

import 'fundus_peer_server_controller.dart';

Future<void> showFundusServerSettings(
  BuildContext context,
  FundusPeerServerController controller,
) => showDialog<void>(
  context: context,
  builder: (context) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 680, maxHeight: 760),
      child: _ServerSettings(controller: controller),
    ),
  ),
);

class _ServerSettings extends StatelessWidget {
  const _ServerSettings({required this.controller});

  final FundusPeerServerController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, child) => Scaffold(
      appBar: AppBar(
        title: const Text('Server & Freigaben'),
        automaticallyImplyLeading: false,
        actions: [
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
          _statusCard(context),
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
                      'Der Server ist derzeit ausschließlich auf diesem Gerät erreichbar. '
                      'LAN-Freigabe, QR/PIN-Pairing und widerrufbare Geräteberechtigungen '
                      'werden vor einer Netzwerkfreigabe ergänzt.',
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
}
