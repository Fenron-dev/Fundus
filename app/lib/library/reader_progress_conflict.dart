import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

import '../playback/playback_conflict_settings.dart';

enum ReaderProgressConflictChoice { keepDevice, useServer }

final class ReaderProgressRevisionView {
  const ReaderProgressRevisionView({
    required this.revision,
    required this.position,
    required this.deviceId,
    required this.deviceName,
    required this.createdAt,
    required this.fileTitle,
  });

  final int revision;
  final MediaPosition position;
  final String deviceId;
  final String deviceName;
  final DateTime createdAt;
  final String fileTitle;
}

typedef ReaderProgressHistoryLoader =
    Future<List<ReaderProgressRevisionView>> Function();
typedef ReaderProgressRevisionRestorer =
    Future<void> Function(ReaderProgressRevisionView revision);

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

/// Any visible difference is offered to the user. A synchronized cache can be
/// older than a position written by another device while this client slept.
bool shouldResolveReaderProgressConflict({
  required bool localPendingSync,
  required MediaPosition? devicePosition,
  required MediaPosition? serverPosition,
}) =>
    devicePosition != null &&
    serverPosition != null &&
    readerPositionsDiffer(devicePosition, serverPosition);

List<ReaderProgressRevisionView> distinctReaderProgressRevisions(
  Iterable<ReaderProgressRevisionView> revisions,
) {
  final seen = <String>{};
  final result = <ReaderProgressRevisionView>[];
  for (final revision in revisions) {
    final position = revision.position;
    final key = [
      revision.deviceId,
      position.kind.name,
      position.fileId ?? '',
      position.numericValue?.round().toString() ?? '',
      position.elementId ?? '',
      position.scrollOffset?.toStringAsFixed(2) ?? '',
    ].join('\u0000');
    if (seen.add(key)) result.add(revision);
  }
  return result;
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

Future<ReaderProgressRevisionView?> showReaderProgressHistory(
  BuildContext context, {
  required ReaderProgressHistoryLoader loadHistory,
  required ReaderProgressRevisionRestorer restoreRevision,
}) => showDialog<ReaderProgressRevisionView>(
  context: context,
  builder: (context) => _ReaderProgressHistoryDialog(
    loadHistory: loadHistory,
    restoreRevision: restoreRevision,
  ),
);

class _ReaderProgressHistoryDialog extends StatefulWidget {
  const _ReaderProgressHistoryDialog({
    required this.loadHistory,
    required this.restoreRevision,
  });

  final ReaderProgressHistoryLoader loadHistory;
  final ReaderProgressRevisionRestorer restoreRevision;

  @override
  State<_ReaderProgressHistoryDialog> createState() =>
      _ReaderProgressHistoryDialogState();
}

class _ReaderProgressHistoryDialogState
    extends State<_ReaderProgressHistoryDialog> {
  late final Future<List<ReaderProgressRevisionView>> _history;
  int? _restoring;
  String? _error;

  @override
  void initState() {
    super.initState();
    _history = widget.loadHistory();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.history),
    title: const Text('Gerätestände'),
    content: SizedBox(
      width: 620,
      child: FutureBuilder<List<ReaderProgressRevisionView>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return const Text('Die Gerätestände konnten nicht geladen werden.');
          }
          final revisions = distinctReaderProgressRevisions(
            snapshot.data ?? const [],
          );
          if (revisions.isEmpty) {
            return const Text('Noch keine früheren Lesestände vorhanden.');
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
                      final item = revisions[index];
                      final restoring = _restoring == item.revision;
                      return ListTile(
                        leading: const Icon(Icons.devices_outlined),
                        title: Text(_readerPositionLabel(item.position)),
                        subtitle: Text(
                          [
                            item.deviceName,
                            item.fileTitle,
                            _readerHistoryDate(item.createdAt),
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
                                onPressed: _restoring == null
                                    ? () => _restore(item)
                                    : null,
                                child: const Text('Dorthin springen'),
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
        onPressed: _restoring == null ? () => Navigator.pop(context) : null,
        child: const Text('Schließen'),
      ),
    ],
  );

  Future<void> _restore(ReaderProgressRevisionView revision) async {
    setState(() {
      _restoring = revision.revision;
      _error = null;
    });
    try {
      await widget.restoreRevision(revision);
      if (mounted) Navigator.pop(context, revision);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _restoring = null;
        _error = 'Dieser Lesestand konnte nicht wiederhergestellt werden.';
      });
    }
  }
}

String _readerPositionLabel(MediaPosition position) {
  final base = position.label?.trim().isNotEmpty == true
      ? position.label!
      : position.displayValue;
  final offset = position.scrollOffset;
  return offset == null
      ? base
      : '$base · ${(offset * 100).round()} % innerhalb der Seite';
}

String _readerHistoryDate(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year}, '
      '${two(local.hour)}:${two(local.minute)} Uhr';
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
