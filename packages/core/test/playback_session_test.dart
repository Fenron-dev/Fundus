import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('playlist snapshot preserves order and current position', () {
    final session = PlaybackSession(
      id: 'session',
      playlistId: 'playlist',
      playlistRevision: 4,
      items: const [
        PlaybackSessionItem(workId: 'a', fileIds: ['a1'], position: 0),
        PlaybackSessionItem(workId: 'b', fileIds: ['b1', 'b2'], position: 1),
      ],
      currentIndex: 1,
      currentPosition: const MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: 90,
        total: 300,
        fileId: 'b2',
      ),
      repeatMode: RepeatMode.all,
      shuffleOrder: const [1, 0],
    );

    expect(session.currentItem.workId, 'b');
    expect(session.currentPosition.fileId, 'b2');
    expect(session.playlistRevision, 4);
    expect(session.validate, returnsNormally);
  });
}
