import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum PlaybackConflictChoice { keepCurrent, useIncoming }

final class PlaybackProgressRevisionView {
  const PlaybackProgressRevisionView({
    required this.revision,
    required this.position,
    required this.track,
    required this.deviceName,
    required this.createdAt,
    this.duration,
    this.chapter,
  });

  final int revision;
  final Duration position;
  final Duration? duration;
  final String track;
  final String? chapter;
  final String deviceName;
  final DateTime createdAt;
}

typedef PlaybackProgressHistoryLoader =
    Future<List<PlaybackProgressRevisionView>> Function();
typedef PlaybackProgressRevisionRestorer =
    Future<void> Function(PlaybackProgressRevisionView revision);

final class PlaybackResumeConflict {
  const PlaybackResumeConflict({
    required this.currentPosition,
    required this.incomingPosition,
    required this.currentTrack,
    required this.incomingTrack,
    required this.currentDevice,
    required this.incomingDevice,
    required this.incomingSource,
    this.currentDuration,
    this.incomingDuration,
    this.currentChapter,
    this.incomingChapter,
    this.loadHistory,
    this.restoreRevision,
  });

  final Duration currentPosition;
  final Duration incomingPosition;
  final Duration? currentDuration;
  final Duration? incomingDuration;
  final String currentTrack;
  final String incomingTrack;
  final String? currentChapter;
  final String? incomingChapter;
  final String currentDevice;
  final String incomingDevice;
  final String incomingSource;
  final PlaybackProgressHistoryLoader? loadHistory;
  final PlaybackProgressRevisionRestorer? restoreRevision;
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
        builder: (context) => PlaybackConflictDialog(conflict: conflict),
      ) ??
      PlaybackConflictChoice.keepCurrent;
}

class PlaybackConflictDialog extends StatelessWidget {
  const PlaybackConflictDialog({required this.conflict, super.key});

  final PlaybackResumeConflict conflict;

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.sync_problem_outlined),
    title: const Text('Abweichender Hörstand gefunden'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: SingleChildScrollView(
        child: Column(
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
              device: conflict.currentDevice,
              track: conflict.currentTrack,
              chapter: conflict.currentChapter,
              position: conflict.currentPosition,
              duration: conflict.currentDuration,
            ),
            const SizedBox(height: 8),
            _PositionCard(
              title: conflict.incomingSource,
              device: conflict.incomingDevice,
              track: conflict.incomingTrack,
              chapter: conflict.incomingChapter,
              position: conflict.incomingPosition,
              duration: conflict.incomingDuration,
            ),
          ],
        ),
      ),
    ),
    actions: [
      if (conflict.loadHistory != null && conflict.restoreRevision != null)
        TextButton.icon(
          onPressed: () => _showHistory(context),
          icon: const Icon(Icons.history),
          label: const Text('Verlauf'),
        ),
      TextButton(
        onPressed: () =>
            Navigator.pop(context, PlaybackConflictChoice.keepCurrent),
        child: const Text('Hier weitermachen'),
      ),
      FilledButton(
        onPressed: () =>
            Navigator.pop(context, PlaybackConflictChoice.useIncoming),
        child: const Text('Anderen Stand übernehmen'),
      ),
    ],
  );

  Future<void> _showHistory(BuildContext context) async {
    final loadHistory = conflict.loadHistory;
    final restoreRevision = conflict.restoreRevision;
    if (loadHistory == null || restoreRevision == null) return;
    final restored = await showDialog<bool>(
      context: context,
      builder: (context) => _ProgressHistoryDialog(
        loadHistory: loadHistory,
        restoreRevision: restoreRevision,
      ),
    );
    if (restored == true && context.mounted) {
      Navigator.pop(context, PlaybackConflictChoice.useIncoming);
    }
  }
}

class _PositionCard extends StatelessWidget {
  const _PositionCard({
    required this.title,
    required this.device,
    required this.track,
    required this.position,
    this.chapter,
    this.duration,
  });

  final String title;
  final String device;
  final String track;
  final String? chapter;
  final Duration position;
  final Duration? duration;

  @override
  Widget build(BuildContext context) {
    final progress = _progress(position, duration);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                const Icon(Icons.devices_outlined, size: 16),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    device,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(track, maxLines: 2, overflow: TextOverflow.ellipsis),
            if (chapter != null && chapter!.trim().isNotEmpty)
              Text(
                'Kapitel: $chapter',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 4),
            Text(
              _positionLabel(position, duration),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (progress != null) ...[
              const SizedBox(height: 6),
              LinearProgressIndicator(value: progress),
            ],
          ],
        ),
      ),
    );
  }
}

class _ProgressHistoryDialog extends StatefulWidget {
  const _ProgressHistoryDialog({
    required this.loadHistory,
    required this.restoreRevision,
  });

  final PlaybackProgressHistoryLoader loadHistory;
  final PlaybackProgressRevisionRestorer restoreRevision;

  @override
  State<_ProgressHistoryDialog> createState() => _ProgressHistoryDialogState();
}

class _ProgressHistoryDialogState extends State<_ProgressHistoryDialog> {
  late final Future<List<PlaybackProgressRevisionView>> _history;
  int? _restoringRevision;
  String? _error;

  @override
  void initState() {
    super.initState();
    _history = widget.loadHistory();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Hörstand-Verlauf'),
    content: SizedBox(
      width: 620,
      child: FutureBuilder<List<PlaybackProgressRevisionView>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Text(
              'Der Hörstand-Verlauf konnte nicht geladen werden.',
            );
          }
          final revisions = snapshot.data ?? const [];
          if (revisions.isEmpty) {
            return const Text('Noch keine früheren Hörstände vorhanden.');
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: revisions.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final revision = revisions[index];
                      final restoring = _restoringRevision == revision.revision;
                      return ListTile(
                        leading: CircleAvatar(
                          child: Text('${revision.revision}'),
                        ),
                        title: Text(
                          _positionLabel(revision.position, revision.duration),
                        ),
                        subtitle: Text(
                          [
                            revision.deviceName,
                            revision.track,
                            if (revision.chapter != null) revision.chapter!,
                            _formatDate(revision.createdAt),
                          ].join(' · '),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: restoring
                            ? const SizedBox.square(
                                dimension: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : TextButton(
                                onPressed: _restoringRevision == null
                                    ? () => _restore(revision)
                                    : null,
                                child: const Text('Wiederherstellen'),
                              ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: _restoringRevision == null
            ? () => Navigator.pop(context, false)
            : null,
        child: const Text('Schließen'),
      ),
    ],
  );

  Future<void> _restore(PlaybackProgressRevisionView revision) async {
    setState(() {
      _restoringRevision = revision.revision;
      _error = null;
    });
    try {
      await widget.restoreRevision(revision);
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _restoringRevision = null;
        _error = 'Dieser Hörstand konnte nicht wiederhergestellt werden.';
      });
    }
  }
}

double? _progress(Duration position, Duration? duration) {
  if (duration == null || duration <= Duration.zero) return null;
  return (position.inMilliseconds / duration.inMilliseconds).clamp(0, 1);
}

String _positionLabel(Duration position, Duration? duration) {
  final total = duration == null || duration <= Duration.zero
      ? null
      : _formatDuration(duration);
  final percentage = _progress(position, duration);
  return [
    total == null
        ? _formatDuration(position)
        : '${_formatDuration(position)} / $total',
    if (percentage != null) '${(percentage * 100).round()} %',
  ].join(' · ');
}

String _formatDuration(Duration value) {
  final hours = value.inHours.toString().padLeft(2, '0');
  final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}.'
      '${local.month.toString().padLeft(2, '0')}.'
      '${local.year} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
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
