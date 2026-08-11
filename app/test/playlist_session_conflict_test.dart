import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playlist_session_conflict.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  final session = PlaybackSession(
    id: 'session',
    playlistId: 'playlist',
    playlistRevision: 1,
    items: const [
      PlaybackSessionItem(workId: 'a', fileIds: ['a-1'], position: 0),
      PlaybackSessionItem(workId: 'b', fileIds: ['b-1'], position: 1),
    ],
    currentIndex: 0,
    currentPosition: const MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: 12,
    ),
    repeatMode: RepeatMode.none,
    shuffleOrder: const [],
  );

  test('detects a changed revision or work order', () {
    final unchanged = LibraryPlaylist(
      id: 'playlist',
      name: 'Liste',
      kind: LibraryPlaylistKind.manual,
      workIds: const ['a', 'b'],
      revision: 1,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final reordered = LibraryPlaylist(
      id: 'playlist',
      name: 'Liste',
      kind: LibraryPlaylistKind.smart,
      workIds: const ['b', 'a'],
      revision: 2,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026, 2),
    );
    expect(playlistSessionHasChanged(session, unchanged), isFalse);
    expect(playlistSessionHasChanged(session, reordered), isTrue);
  });

  testWidgets('offers old session or current playlist', (tester) async {
    late BuildContext dialogContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            dialogContext = context;
            return const SizedBox();
          },
        ),
      ),
    );
    final conflict = PlaylistSessionConflict(
      playlistName: 'Unterwegs',
      sessionRevision: 1,
      currentRevision: 3,
      sessionWorkIds: const ['a', 'b'],
      currentWorkIds: const ['b', 'c'],
    );
    final result = resolvePlaylistSessionConflict(dialogContext, conflict);
    await tester.pumpAndSettle();

    expect(find.text('Playlist wurde geändert'), findsOneWidget);
    expect(find.text('1 hinzugefügt · 1 entfernt'), findsOneWidget);
    await tester.tap(find.text('Aktuelle Liste übernehmen'));
    await tester.pumpAndSettle();
    expect(await result, PlaylistSessionChoice.useCurrentPlaylist);
  });
}
