import 'package:flutter/material.dart';

Future<bool> confirmPlaybackTrackJump(
  BuildContext context, {
  required String currentTitle,
  required String targetTitle,
  required Duration currentPosition,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Zu einer anderen Datei springen?'),
      content: Text(
        'Du hörst „$currentTitle“ gerade bei ${_formatTime(currentPosition)}. '
        'Beim Wechsel zu „$targetTitle“ wird dieser Stand gespeichert.\n\n'
        'So verhindert Fundus, dass ein versehentliches Antippen deine '
        'aktuelle Position überschreibt.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Abbrechen'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Datei wechseln'),
        ),
      ],
    ),
  );
  return result ?? false;
}

String _formatTime(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
