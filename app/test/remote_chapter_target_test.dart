import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_client.dart';
import 'package:fundus/server/fundus_remote_player_controller.dart';

void main() {
  test('chapter jump resolves its remote track and position', () {
    const tracks = [
      FundusRemoteTrack(id: 'file-1', title: 'Teil 1', position: 0),
      FundusRemoteTrack(id: 'file-2', title: 'Teil 2', position: 1),
    ];
    const chapter = FundusRemoteChapter(
      title: 'Das zweite Kapitel',
      fileId: 'file-2',
      trackIndex: 1,
      position: Duration(minutes: 12, seconds: 34),
    );

    final target = resolveRemoteChapterTarget(tracks, chapter);

    expect(target, isNotNull);
    expect(target!.trackIndex, 1);
    expect(target.position, const Duration(minutes: 12, seconds: 34));
  });

  test('chapter jump recovers from a stale track index via opaque file id', () {
    const tracks = [
      FundusRemoteTrack(id: 'file-1', title: 'Teil 1', position: 0),
      FundusRemoteTrack(id: 'file-2', title: 'Teil 2', position: 1),
    ];
    const chapter = FundusRemoteChapter(
      title: 'Verschobenes Kapitel',
      fileId: 'file-2',
      trackIndex: 0,
      position: Duration(seconds: 20),
    );

    final target = resolveRemoteChapterTarget(tracks, chapter);

    expect(target?.trackIndex, 1);
    expect(target?.position, const Duration(seconds: 20));
  });
}
