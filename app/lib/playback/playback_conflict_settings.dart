import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum PlaybackConflictChoice { keepCurrent, useIncoming }

final class PlaybackResumeConflict {
  const PlaybackResumeConflict({
    required this.currentPosition,
    required this.incomingPosition,
    required this.currentTrack,
    required this.incomingTrack,
    required this.incomingSource,
  });

  final Duration currentPosition;
  final Duration incomingPosition;
  final String currentTrack;
  final String incomingTrack;
  final String incomingSource;
}

typedef PlaybackConflictResolver =
    Future<PlaybackConflictChoice> Function(PlaybackResumeConflict conflict);

abstract final class PlaybackConflictSettings {
  static const _storage = FlutterSecureStorage();
  static const _askKey = 'fundus.playback.ask_on_progress_conflict.v1';

  static Future<bool> askBeforeJumping() async {
    final value = await _storage.read(key: _askKey);
    return value != 'false';
  }

  static Future<void> setAskBeforeJumping(bool value) =>
      _storage.write(key: _askKey, value: '$value');
}

Future<PlaybackConflictChoice> resolvePlaybackConflict(
  BuildContext context,
  PlaybackResumeConflict conflict,
) async {
  if (!await PlaybackConflictSettings.askBeforeJumping()) {
    return PlaybackConflictChoice.useIncoming;
  }
  if (!context.mounted) return PlaybackConflictChoice.keepCurrent;
  return await showDialog<PlaybackConflictChoice>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.sync_problem_outlined),
          title: const Text('Neuerer Hörstand gefunden'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${conflict.incomingSource} enthält einen neueren oder '
                'abweichenden Hörstand.',
              ),
              const SizedBox(height: 16),
              _PositionCard(
                title: 'Aktueller Player',
                track: conflict.currentTrack,
                position: conflict.currentPosition,
              ),
              const SizedBox(height: 8),
              _PositionCard(
                title: conflict.incomingSource,
                track: conflict.incomingTrack,
                position: conflict.incomingPosition,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, PlaybackConflictChoice.keepCurrent),
              child: const Text('Hier weitermachen'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, PlaybackConflictChoice.useIncoming),
              child: const Text('Neueren Stand übernehmen'),
            ),
          ],
        ),
      ) ??
      PlaybackConflictChoice.keepCurrent;
}

class _PositionCard extends StatelessWidget {
  const _PositionCard({
    required this.title,
    required this.track,
    required this.position,
  });

  final String title;
  final String track;
  final Duration position;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(track, maxLines: 2, overflow: TextOverflow.ellipsis),
          Text(
            _format(position),
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ],
      ),
    ),
  );

  static String _format(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
}

class PlaybackConflictSettingTile extends StatefulWidget {
  const PlaybackConflictSettingTile({super.key});

  @override
  State<PlaybackConflictSettingTile> createState() =>
      _PlaybackConflictSettingTileState();
}

class _PlaybackConflictSettingTileState
    extends State<PlaybackConflictSettingTile> {
  bool? _value;

  @override
  void initState() {
    super.initState();
    PlaybackConflictSettings.askBeforeJumping().then((value) {
      if (mounted) setState(() => _value = value);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    secondary: const Icon(Icons.sync_problem_outlined),
    title: const Text('Bei abweichendem Hörstand nachfragen'),
    subtitle: const Text(
      'Aus: Fundus übernimmt automatisch den neueren Stand.',
    ),
    value: _value ?? true,
    onChanged: _value == null
        ? null
        : (value) async {
            await PlaybackConflictSettings.setAskBeforeJumping(value);
            if (mounted) setState(() => _value = value);
          },
  );
}
