import 'package:fundus_core/fundus_core.dart';

import '../server/fundus_offline_store.dart';
import '../server/fundus_remote_client.dart';

enum WorkDetailOrigin { local, remote, offline }

/// Normalizes the metadata needed by cards and detail views without making
/// those widgets depend on a transport- or storage-specific work model.
final class WorkDetailViewModel {
  const WorkDetailViewModel({
    required this.summary,
    required this.origin,
    required this.hasRemoteCover,
    this.sourceServerId,
    this.sourceLibraryId,
  });

  factory WorkDetailViewModel.fromLibrary(LibraryWorkSummary work) =>
      WorkDetailViewModel(
        summary: work,
        origin: work.offline
            ? WorkDetailOrigin.offline
            : WorkDetailOrigin.local,
        hasRemoteCover: false,
      );

  factory WorkDetailViewModel.fromRemote(
    FundusRemoteWork work, {
    required String serverId,
    required String libraryId,
    String? serverName,
    String? libraryName,
    bool offlineAvailable = false,
  }) => WorkDetailViewModel(
    summary: LibraryWorkSummary(
      id: work.id,
      kind: work.kind,
      title: work.title,
      author: work.authors.firstOrNull ?? 'Unbekannt',
      authors: work.authors,
      fileCount: work.fileCount,
      addedAt: work.addedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      series: work.series,
      seriesSequence: work.seriesSequence?.toDouble(),
      coverVersion: work.coverVersion,
      language: work.language,
      genres: _providerGenres(work.providerMetadata),
      subtitle: work.subtitle,
      description: work.description,
      narrators: work.narrators,
      publisher: work.publisher,
      publishedYear: work.publishedYear,
      progressPosition: work.progressPosition,
      progressDuration: work.progressDuration,
      progressTrackIndex: work.progressTrackIndex,
      progressFinished: work.progressFinished,
      contentSensitivity: work.contentSensitivity,
      contentStyle: work.contentStyle,
      tags: work.tags,
      lastListenedAt: work.lastListenedAt,
      offline: offlineAvailable,
      sourceId: 'remote:$serverId/$libraryId',
      availability: offlineAvailable ? 'offline' : 'available',
      sourceServerName: serverName ?? serverId,
      sourceLibraryName: libraryName ?? libraryId,
      providerMetadata: work.providerMetadata,
    ),
    origin: WorkDetailOrigin.remote,
    hasRemoteCover: work.hasCover,
    sourceServerId: serverId,
    sourceLibraryId: libraryId,
  );

  factory WorkDetailViewModel.fromOffline(
    FundusOfflineWork work, {
    String? summaryId,
  }) {
    final progress = work.progress;
    final progressTrackIndex = progress?.fileId == null
        ? null
        : work.tracks.indexWhere((track) => track.id == progress!.fileId);
    return WorkDetailViewModel(
      summary: LibraryWorkSummary(
        id: summaryId ?? work.workId,
        kind: work.kind,
        title: work.title,
        author: work.authors.firstOrNull ?? 'Unbekannt',
        authors: work.authors,
        fileCount: work.tracks.length,
        addedAt: work.downloadedAt,
        series: work.series,
        seriesSequence: work.seriesSequence?.toDouble(),
        coverPath: work.coverPath,
        offlinePath: work.directoryPath,
        language: work.language,
        subtitle: work.subtitle,
        description: work.description,
        narrators: work.narrators,
        publisher: work.publisher,
        publishedYear: work.publishedYear,
        progressPosition: progress?.position,
        progressDuration: progress?.duration,
        mediaProgress: progress?.mediaPosition,
        progressTrackIndex:
            progressTrackIndex != null && progressTrackIndex >= 0
            ? progressTrackIndex
            : null,
        progressFinished: progress?.finished ?? false,
        contentSensitivity: work.contentSensitivity,
        contentStyle: work.contentStyle,
        lastListenedAt: progress?.updatedAt,
        status: work.incomplete ? 'incomplete' : 'available',
        tags: work.tags,
        offline: true,
        sourceId: work.sourceId,
        availability: 'offline',
        sourceServerName: work.sourceServerName ?? work.serverId,
        sourceLibraryName: work.sourceLibraryName ?? work.libraryId,
        providerMetadata: work.providerMetadata,
      ),
      origin: WorkDetailOrigin.offline,
      hasRemoteCover: false,
      sourceServerId: work.serverId,
      sourceLibraryId: work.libraryId,
    );
  }

  final LibraryWorkSummary summary;
  final WorkDetailOrigin origin;
  final bool hasRemoteCover;
  final String? sourceServerId;
  final String? sourceLibraryId;

  bool get isOffline => origin == WorkDetailOrigin.offline;
  bool get isRemote => origin == WorkDetailOrigin.remote;
}

List<String> _providerGenres(Map<String, Object?> metadata) {
  final value = metadata['genres'];
  return value is List
      ? value
            .whereType<String>()
            .where((item) => item.trim().isNotEmpty)
            .toList(growable: false)
      : const [];
}
