import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/work_detail_view_model.dart';
import 'package:fundus/server/fundus_offline_store.dart';
import 'package:fundus/server/fundus_remote_client.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('remote details retain source labels and playback metadata', () {
    final updated = DateTime.utc(2026, 8, 26, 12, 30);
    final detail = WorkDetailViewModel.fromRemote(
      FundusRemoteWork(
        id: 'work-1',
        title: 'Remote Novel',
        authors: const ['Autorin'],
        hasCover: true,
        kind: 'webnovel',
        fileCount: 2,
        tags: const ['Fantasy'],
        progressFinished: true,
        lastListenedAt: updated,
      ),
      serverId: 'server-id',
      libraryId: 'library-id',
      serverName: 'MacBook',
      libraryName: 'Fundus Vault',
      offlineAvailable: true,
    );

    expect(detail.origin, WorkDetailOrigin.remote);
    expect(detail.hasRemoteCover, isTrue);
    expect(detail.summary.sourceServerName, 'MacBook');
    expect(detail.summary.sourceLibraryName, 'Fundus Vault');
    expect(detail.summary.sourceId, 'remote:server-id/library-id');
    expect(detail.summary.availability, 'offline');
    expect(detail.summary.offline, isTrue);
    expect(detail.summary.progressFinished, isTrue);
    expect(detail.summary.lastListenedAt, updated);
  });

  test('offline details retain cover, position and incomplete state', () {
    final updated = DateTime.utc(2026, 8, 26, 13);
    const position = MediaPosition(
      kind: MediaPositionKind.page,
      numericValue: 12,
      fileId: 'chapter-2',
    );
    final detail = WorkDetailViewModel.fromOffline(
      FundusOfflineWork(
        serverId: 'server-id',
        libraryId: 'library-id',
        workId: 'work-1',
        title: 'Offline Manga',
        downloadedAt: DateTime.utc(2026, 8, 25),
        tracks: const [
          FundusOfflineTrack(
            id: 'chapter-1',
            title: 'Kapitel 1',
            path: '/offline/1.cbz',
            position: 0,
          ),
          FundusOfflineTrack(
            id: 'chapter-2',
            title: 'Kapitel 2',
            path: '/offline/2.cbz',
            position: 1,
          ),
        ],
        sourceServerName: 'Rechner',
        sourceLibraryName: 'Comics',
        kind: 'manga',
        authors: const ['Zeichner'],
        coverPath: '/offline/cover.webp',
        missingTrackTitles: const ['Kapitel 3'],
        progress: FundusRemoteProgress(
          fileId: 'chapter-2',
          position: Duration.zero,
          finished: false,
          revision: 3,
          mediaPosition: position,
          updatedAt: updated,
        ),
      ),
      summaryId: 'offline:work-1',
    );

    expect(detail.origin, WorkDetailOrigin.offline);
    expect(detail.summary.id, 'offline:work-1');
    expect(detail.summary.coverPath, '/offline/cover.webp');
    expect(detail.summary.offlinePath, '/offline');
    expect(detail.summary.mediaProgress, position);
    expect(detail.summary.progressTrackIndex, 1);
    expect(detail.summary.status, 'incomplete');
    expect(detail.summary.sourceServerName, 'Rechner');
    expect(detail.summary.sourceLibraryName, 'Comics');
    expect(detail.summary.sourceId, 'remote:server-id/library-id');
    expect(detail.summary.availability, 'offline');
    expect(detail.summary.lastListenedAt, updated);
  });

  test('local details preserve the original summary', () {
    final summary = LibraryWorkSummary(
      id: 'local-1',
      kind: 'document',
      title: 'Regelwerk',
      author: 'Autor',
      fileCount: 1,
      addedAt: DateTime.utc(2026, 8, 26),
    );

    final detail = WorkDetailViewModel.fromLibrary(summary);

    expect(detail.origin, WorkDetailOrigin.local);
    expect(detail.summary, same(summary));
  });
}
