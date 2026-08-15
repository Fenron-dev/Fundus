import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

import '../playback/playback_conflict_settings.dart';

enum ReaderProgressConflictChoice { keepDevice, useServer }

bool readerPositionsDiffer(MediaPosition device, MediaPosition server) {
  if (device.kind != server.kind || device.fileId != server.fileId) return true;
  if ((device.numericValue ?? 0).round() !=
      (server.numericValue ?? 0).round()) {
    return true;
  }
  final deviceOffset = device.scrollOffset;
  final serverOffset = server.scrollOffset;
  return deviceOffset != null &&
      serverOffset != null &&
      (deviceOffset - serverOffset).abs() > .05;
}

Future<ReaderProgressConflictChoice> resolveReaderProgressConflict(
  BuildContext context, {
  required MediaPosition devicePosition,
  required MediaPosition serverPosition,
  required String deviceName,
  required String serverDeviceName,
  bool? askBeforeJumping,
}) async {
  if (!(askBeforeJumping ??
      await PlaybackConflictSettings.askBeforeJumping())) {
    return ReaderProgressConflictChoice.useServer;
  }
  if (!context.mounted) return ReaderProgressConflictChoice.keepDevice;
  return await showDialog<ReaderProgressConflictChoice>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.sync_problem_outlined),
          title: const Text('Abweichender Lesestand gefunden'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Auf diesem Gerät und dem Server sind unterschiedliche '
                    'Positionen gespeichert. Wähle aus, wo du weiterlesen willst.',
                  ),
                  const SizedBox(height: 16),
                  _ReaderPositionCard(
                    title: 'Dieses Gerät',
                    device: deviceName,
                    position: devicePosition,
                  ),
                  const SizedBox(height: 10),
                  _ReaderPositionCard(
                    title: 'Serverstand',
                    device: serverDeviceName,
                    position: serverPosition,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                ReaderProgressConflictChoice.keepDevice,
              ),
              child: const Text('Dieses Gerät'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                ReaderProgressConflictChoice.useServer,
              ),
              child: const Text('Serverstand übernehmen'),
            ),
          ],
        ),
      ) ??
      ReaderProgressConflictChoice.keepDevice;
}

class _ReaderPositionCard extends StatelessWidget {
  const _ReaderPositionCard({
    required this.title,
    required this.device,
    required this.position,
  });

  final String title;
  final String device;
  final MediaPosition position;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(device),
          Text(position.label ?? position.displayValue),
          if (position.chapterId case final chapter?) Text(chapter),
          if (position.fraction case final fraction?) ...[
            const SizedBox(height: 8),
            LinearProgressIndicator(value: fraction),
          ],
        ],
      ),
    ),
  );
}
