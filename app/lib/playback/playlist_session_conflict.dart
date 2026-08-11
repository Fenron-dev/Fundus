import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

enum PlaylistSessionChoice { keepSession, useCurrentPlaylist }

final class PlaylistSessionConflict {
  const PlaylistSessionConflict({
    required this.playlistName,
    required this.sessionRevision,
    required this.currentRevision,
    required this.sessionWorkIds,
    required this.currentWorkIds,
  });

  final String playlistName;
  final int sessionRevision;
  final int currentRevision;
  final List<String> sessionWorkIds;
  final List<String> currentWorkIds;

  int get addedCount =>
      currentWorkIds.where((workId) => !sessionWorkIds.contains(workId)).length;

  int get removedCount =>
      sessionWorkIds.where((workId) => !currentWorkIds.contains(workId)).length;

  bool get orderChanged {
    final sharedBefore = sessionWorkIds
        .where(currentWorkIds.contains)
        .toList(growable: false);
    final sharedNow = currentWorkIds
        .where(sessionWorkIds.contains)
        .toList(growable: false);
    return !_sameOrder(sharedBefore, sharedNow);
  }
}

typedef PlaylistSessionConflictResolver =
    Future<PlaylistSessionChoice> Function(PlaylistSessionConflict conflict);

bool playlistSessionHasChanged(
  PlaybackSession session,
  LibraryPlaylist playlist,
) =>
    session.playlistId == playlist.id &&
    (session.playlistRevision != playlist.revision ||
        !_sameOrder(
          session.items.map((item) => item.workId).toList(growable: false),
          playlist.workIds,
        ));

Future<PlaylistSessionChoice> resolvePlaylistSessionConflict(
  BuildContext context,
  PlaylistSessionConflict conflict,
) async {
  if (!context.mounted) return PlaylistSessionChoice.keepSession;
  return await showDialog<PlaylistSessionChoice>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.playlist_add_check_circle_outlined),
          title: const Text('Playlist wurde geändert'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '„${conflict.playlistName}“ hat sich seit der pausierten '
                'Wiedergabe geändert.',
              ),
              const SizedBox(height: 16),
              _RevisionCard(
                title: 'Pausierte Sitzung',
                revision: conflict.sessionRevision,
                workCount: conflict.sessionWorkIds.length,
              ),
              const SizedBox(height: 8),
              _RevisionCard(
                title: 'Aktuelle Playlist',
                revision: conflict.currentRevision,
                workCount: conflict.currentWorkIds.length,
              ),
              const SizedBox(height: 12),
              Text(
                [
                  if (conflict.addedCount > 0)
                    '${conflict.addedCount} hinzugefügt',
                  if (conflict.removedCount > 0)
                    '${conflict.removedCount} entfernt',
                  if (conflict.orderChanged) 'Reihenfolge geändert',
                ].join(' · '),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, PlaylistSessionChoice.keepSession),
              child: const Text('Alte Sitzung fortsetzen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                PlaylistSessionChoice.useCurrentPlaylist,
              ),
              child: const Text('Aktuelle Liste übernehmen'),
            ),
          ],
        ),
      ) ??
      PlaylistSessionChoice.keepSession;
}

bool _sameOrder(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class _RevisionCard extends StatelessWidget {
  const _RevisionCard({
    required this.title,
    required this.revision,
    required this.workCount,
  });

  final String title;
  final int revision;
  final int workCount;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: ListTile(
      dense: true,
      title: Text(title),
      subtitle: Text('$workCount Werk(e)'),
      trailing: Text('Rev. $revision'),
    ),
  );
}
