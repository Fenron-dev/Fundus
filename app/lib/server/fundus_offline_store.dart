import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'fundus_remote_client.dart';

final class FundusOfflineTrack {
  const FundusOfflineTrack({
    required this.id,
    required this.title,
    required this.path,
    required this.position,
    this.duration,
    this.audioMetadata,
  });

  final String id;
  final String title;
  final String path;
  final int position;
  final Duration? duration;
  final AudioTechnicalMetadata? audioMetadata;
}

final class FundusOfflineWork {
  const FundusOfflineWork({
    required this.serverId,
    required this.libraryId,
    required this.workId,
    required this.title,
    required this.downloadedAt,
    required this.tracks,
    this.sourceServerName,
    this.sourceLibraryName,
    this.chapters = const [],
    this.kind = 'audiobook',
    this.authors = const [],
    this.subtitle,
    this.series,
    this.seriesSequence,
    this.narrators = const [],
    this.language,
    this.description,
    this.publisher,
    this.publishedYear,
    this.coverPath,
    this.tags = const [],
    this.progress,
    this.missingTrackTitles = const [],
  });

  final String serverId;
  final String libraryId;
  final String workId;
  final String title;
  final DateTime downloadedAt;
  final List<FundusOfflineTrack> tracks;
  final String? sourceServerName;
  final String? sourceLibraryName;
  final List<FundusRemoteChapter> chapters;
  final String kind;
  final List<String> authors;
  final String? subtitle;
  final String? series;
  final num? seriesSequence;
  final List<String> narrators;
  final String? language;
  final String? description;
  final String? publisher;
  final int? publishedYear;
  final String? coverPath;
  final List<String> tags;
  final FundusRemoteProgress? progress;
  final List<String> missingTrackTitles;

  bool get incomplete => missingTrackTitles.isNotEmpty;

  String get directoryPath => p.dirname(tracks.first.path);

  Duration get totalDuration => tracks.fold(
    Duration.zero,
    (total, track) => total + (track.duration ?? Duration.zero),
  );
}

final class FundusOfflinePendingProgress {
  const FundusOfflinePendingProgress({
    required this.serverId,
    required this.libraryId,
    required this.workId,
    required this.fileId,
    required this.position,
    required this.finished,
    required this.operationId,
    this.mediaPosition,
  });

  final String serverId;
  final String libraryId;
  final String workId;
  final String fileId;
  final Duration position;
  final bool finished;
  final String operationId;
  final MediaPosition? mediaPosition;
}

typedef OfflineDownloadProgress = void Function(int completed, int total);
typedef OfflineDownloadTransferProgress =
    void Function(
      int fileIndex,
      int fileCount,
      int receivedBytes,
      int? totalBytes,
    );

final class FundusOfflineStore {
  FundusOfflineStore({
    Directory? root,
    List<FundusOfflineStore> fallbacks = const [],
  }) : _configuredRoot = root,
       _fallbacks = List.unmodifiable(fallbacks);

  factory FundusOfflineStore.forLibrary(
    Directory libraryRoot, {
    List<FundusOfflineStore> fallbacks = const [],
  }) => FundusOfflineStore(
    root: Directory(
      p.join(libraryRoot.absolute.path, '_fundus', 'offline-media'),
    ),
    fallbacks: fallbacks,
  );

  final Directory? _configuredRoot;
  final List<FundusOfflineStore> _fallbacks;

  Future<Directory> _root() async {
    final configured = _configuredRoot;
    if (configured != null) return configured;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'offline-media'));
  }

  Future<FundusOfflineWork?> lookup({
    required String serverId,
    required String libraryId,
    required String workId,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, workId);
    final manifest = File(p.join(directory.path, 'manifest.json'));
    if (!await manifest.exists()) {
      for (final fallback in _fallbacks) {
        final work = await fallback.lookup(
          serverId: serverId,
          libraryId: libraryId,
          workId: workId,
        );
        if (work != null) return work;
      }
      return null;
    }
    try {
      final value = jsonDecode(await manifest.readAsString());
      if (value is! Map) return null;
      final tracksValue = value['tracks'];
      if (tracksValue is! List) return null;
      final tracks = <FundusOfflineTrack>[];
      final missingTrackTitles = <String>[];
      for (final item in tracksValue.whereType<Map>()) {
        final relativePath = item['path'];
        if (item['id'] is! String ||
            item['title'] is! String ||
            relativePath is! String) {
          return null;
        }
        final absolutePath = p.normalize(p.join(directory.path, relativePath));
        if (!p.isWithin(directory.path, absolutePath) ||
            !await File(absolutePath).exists()) {
          missingTrackTitles.add(item['title'] as String);
          continue;
        }
        tracks.add(
          FundusOfflineTrack(
            id: item['id'] as String,
            title: item['title'] as String,
            path: absolutePath,
            position: item['position'] is int ? item['position'] as int : 0,
            duration: item['duration_ms'] is int
                ? Duration(milliseconds: item['duration_ms'] as int)
                : null,
            audioMetadata: _audioMetadata(item['audio']),
          ),
        );
      }
      if (tracks.isEmpty) return null;
      tracks.sort((a, b) => a.position.compareTo(b.position));
      final trackIndexById = <String, int>{
        for (var index = 0; index < tracks.length; index++)
          tracks[index].id: index,
      };
      final chapters = <FundusRemoteChapter>[];
      for (final item
          in (value['chapters'] as List? ?? const []).whereType<Map>()) {
        final fileId = item['file_id'];
        final trackIndex = fileId is String ? trackIndexById[fileId] : null;
        final positionMs = item['position_ms'];
        if (item['title'] is! String ||
            fileId is! String ||
            trackIndex == null ||
            positionMs is! int ||
            positionMs < 0) {
          continue;
        }
        final durationMs = item['duration_ms'];
        chapters.add(
          FundusRemoteChapter(
            title: item['title'] as String,
            fileId: fileId,
            trackIndex: trackIndex,
            position: Duration(milliseconds: positionMs),
            duration: durationMs is int && durationMs >= 0
                ? Duration(milliseconds: durationMs)
                : null,
          ),
        );
      }
      final coverValue = value['cover_path'];
      final coverPath = coverValue is String
          ? p.normalize(p.join(directory.path, coverValue))
          : null;
      final progress = await _loadProgressFromDirectory(directory);
      return FundusOfflineWork(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        title: value['title'] is String ? value['title'] as String : 'Medium',
        sourceServerName: value['server_name'] is String
            ? value['server_name'] as String
            : null,
        sourceLibraryName: value['library_name'] is String
            ? value['library_name'] as String
            : null,
        kind: value['kind'] is String ? value['kind'] as String : 'audiobook',
        authors: (value['authors'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        subtitle: value['subtitle'] is String
            ? value['subtitle'] as String
            : null,
        series: value['series'] is String ? value['series'] as String : null,
        seriesSequence: value['series_sequence'] is num
            ? value['series_sequence'] as num
            : null,
        narrators: (value['narrators'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        language: value['language'] is String
            ? value['language'] as String
            : null,
        description: value['description'] is String
            ? value['description'] as String
            : null,
        publisher: value['publisher'] is String
            ? value['publisher'] as String
            : null,
        publishedYear: value['published_year'] is int
            ? value['published_year'] as int
            : null,
        tags: (value['tags'] as List? ?? const []).whereType<String>().toList(
          growable: false,
        ),
        downloadedAt:
            DateTime.tryParse('${value['downloaded_at'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        tracks: tracks,
        chapters: chapters,
        coverPath:
            coverPath != null &&
                p.isWithin(directory.path, coverPath) &&
                await File(coverPath).exists()
            ? coverPath
            : null,
        progress: progress,
        missingTrackTitles: List.unmodifiable(missingTrackTitles),
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<List<FundusOfflineWork>> listAll() async {
    final root = await _root();
    final byKey = <String, FundusOfflineWork>{};
    if (await root.exists()) {
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final manifest = File(p.join(entity.path, 'manifest.json'));
        if (!await manifest.exists()) continue;
        try {
          final value = jsonDecode(await manifest.readAsString());
          if (value is! Map ||
              value['server_id'] is! String ||
              value['library_id'] is! String ||
              value['work_id'] is! String) {
            continue;
          }
          final work = await lookup(
            serverId: value['server_id'] as String,
            libraryId: value['library_id'] as String,
            workId: value['work_id'] as String,
          );
          if (work != null) byKey[_workKey(work)] = work;
        } on FormatException {
          continue;
        } on FileSystemException {
          continue;
        }
      }
    }
    for (final fallback in _fallbacks) {
      for (final work in await fallback.listAll()) {
        byKey.putIfAbsent(_workKey(work), () => work);
      }
    }
    final result = byKey.values.toList();
    result.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return result;
  }

  Future<int> adoptFallbackDownloads() async {
    if (_configuredRoot == null || _fallbacks.isEmpty) return 0;
    final root = await _root();
    await root.create(recursive: true);
    var adopted = 0;
    for (final fallback in _fallbacks) {
      for (final work in await fallback.listAll()) {
        final destination = await _workDirectory(
          work.serverId,
          work.libraryId,
          work.workId,
        );
        if (await File(p.join(destination.path, 'manifest.json')).exists()) {
          continue;
        }
        final source = await fallback._workDirectory(
          work.serverId,
          work.libraryId,
          work.workId,
        );
        if (!await source.exists()) continue;
        final temporary = Directory('${destination.path}.adopting');
        try {
          if (await temporary.exists()) await temporary.delete(recursive: true);
          await _copyDirectory(source, temporary);
          if (!await File(p.join(temporary.path, 'manifest.json')).exists()) {
            throw const FileSystemException(
              'Der übernommene Download enthält kein Manifest.',
            );
          }
          if (await destination.exists()) {
            await destination.delete(recursive: true);
          }
          await temporary.rename(destination.path);
          adopted++;
          await _appendLedger('adopted', {
            'server_id': work.serverId,
            'library_id': work.libraryId,
            'work_id': work.workId,
            'title': work.title,
          });
        } on FileSystemException {
          if (await temporary.exists()) {
            await temporary.delete(recursive: true);
          }
        }
      }
    }
    return adopted;
  }

  static Future<void> _copyDirectory(
    Directory source,
    Directory destination,
  ) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final targetPath = p.join(destination.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(targetPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      }
    }
  }

  Future<FundusOfflineWork?> updateSourceLabels({
    required String serverId,
    required String libraryId,
    required String workId,
    required String serverName,
    required String libraryName,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, workId);
    final manifest = File(p.join(directory.path, 'manifest.json'));
    if (!await manifest.exists()) {
      for (final fallback in _fallbacks) {
        final updated = await fallback.updateSourceLabels(
          serverId: serverId,
          libraryId: libraryId,
          workId: workId,
          serverName: serverName,
          libraryName: libraryName,
        );
        if (updated != null) return updated;
      }
      return null;
    }
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map) return null;
      if (decoded['server_name'] == serverName &&
          decoded['library_name'] == libraryName) {
        return lookup(serverId: serverId, libraryId: libraryId, workId: workId);
      }
      final value = Map<String, Object?>.from(decoded)
        ..['server_name'] = serverName
        ..['library_name'] = libraryName;
      final partial = File('${manifest.path}.part');
      await partial.writeAsString(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      if (await manifest.exists()) await manifest.delete();
      await partial.rename(manifest.path);
      return lookup(serverId: serverId, libraryId: libraryId, workId: workId);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<FundusOfflineWork?> refreshMetadata({
    required String serverId,
    required String libraryId,
    required FundusRemoteWork work,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, work.id);
    final manifest = File(p.join(directory.path, 'manifest.json'));
    if (!await manifest.exists()) {
      for (final fallback in _fallbacks) {
        final refreshed = await fallback.refreshMetadata(
          serverId: serverId,
          libraryId: libraryId,
          work: work,
        );
        if (refreshed != null) return refreshed;
      }
      return null;
    }
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map) return null;
      final value = Map<String, Object?>.from(decoded);
      value
        ..['title'] = work.title
        ..['kind'] = work.kind
        ..['authors'] = work.authors
        ..['subtitle'] = work.subtitle
        ..['series'] = work.series
        ..['series_sequence'] = work.seriesSequence
        ..['narrators'] = work.narrators
        ..['language'] = work.language
        ..['description'] = work.description
        ..['publisher'] = work.publisher
        ..['published_year'] = work.publishedYear;
      value['tags'] = work.tags;
      final partial = File('${manifest.path}.part');
      await partial.writeAsString(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      await manifest.delete();
      await partial.rename(manifest.path);
      final refreshed = await lookup(
        serverId: serverId,
        libraryId: libraryId,
        workId: work.id,
      );
      final trackIndex = work.progressTrackIndex;
      final position = work.progressPosition;
      if (refreshed != null &&
          trackIndex != null &&
          trackIndex >= 0 &&
          trackIndex < refreshed.tracks.length &&
          position != null) {
        await cacheProgress(
          serverId: serverId,
          libraryId: libraryId,
          workId: work.id,
          progress: FundusRemoteProgress(
            fileId: refreshed.tracks[trackIndex].id,
            position: position,
            finished: work.progressFinished,
            revision: 0,
          ),
        );
      }
      return refreshed;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<FundusOfflineWork> download(
    FundusRemoteClient client,
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    Set<String>? trackIds,
    OfflineDownloadProgress? onProgress,
    OfflineDownloadTransferProgress? onTransfer,
  }) async {
    final detail = await client.work(server, library.id, work);
    final selectedTracks = trackIds == null
        ? detail.tracks
        : detail.tracks
              .where((track) => trackIds.contains(track.id))
              .toList(growable: false);
    if (selectedTracks.isEmpty) {
      throw StateError('Dieses Werk enthält keine herunterladbaren Dateien.');
    }
    final directory = await _workDirectory(server.id, library.id, work.id);
    await directory.create(recursive: true);
    final existing = await lookup(
      serverId: server.id,
      libraryId: library.id,
      workId: work.id,
    );
    final offlineTracks = <FundusOfflineTrack>[
      for (final track in existing?.tracks ?? const <FundusOfflineTrack>[])
        if (await File(track.path).exists()) track,
    ];
    final existingIds = offlineTracks.map((track) => track.id).toSet();
    final pendingTracks = selectedTracks
        .where((track) => !existingIds.contains(track.id))
        .toList(growable: false);
    var completed = 0;
    onProgress?.call(completed, pendingTracks.length);
    try {
      for (var index = 0; index < pendingTracks.length; index++) {
        final track = pendingTracks[index];
        final sourceIndex = detail.tracks.indexWhere(
          (candidate) => candidate.id == track.id,
        );
        final filename =
            '${sourceIndex.toString().padLeft(4, '0')}${_extension(track.title)}';
        final destination = File(p.join(directory.path, filename));
        final partial = File('${destination.path}.part');
        if (await partial.exists()) await partial.delete();
        final remote = await client.openContent(
          server,
          libraryId: library.id,
          fileId: track.id,
        );
        IOSink? sink;
        try {
          sink = partial.openWrite();
          var received = 0;
          final expected = remote.response.contentLength > 0
              ? remote.response.contentLength
              : null;
          onTransfer?.call(index, pendingTracks.length, received, expected);
          await sink.addStream(
            remote.response.timeout(const Duration(seconds: 30)).map((chunk) {
              received += chunk.length;
              onTransfer?.call(index, pendingTracks.length, received, expected);
              return chunk;
            }),
          );
          await sink.close();
          sink = null;
        } finally {
          await sink?.close();
          remote.close();
        }
        if (await destination.exists()) await destination.delete();
        await partial.rename(destination.path);
        offlineTracks.add(
          FundusOfflineTrack(
            id: track.id,
            title: track.title,
            path: destination.path,
            position: track.position,
            duration: track.duration,
            audioMetadata: track.audioMetadata,
          ),
        );
        completed++;
        onProgress?.call(completed, pendingTracks.length);
      }
      offlineTracks.sort(
        (left, right) => left.position.compareTo(right.position),
      );
      String? coverPath;
      if (work.hasCover) {
        try {
          final cover = File(p.join(directory.path, 'cover'));
          await cover.writeAsBytes(
            await client.cover(server, library.id, work.id),
            flush: true,
          );
          coverPath = cover.path;
        } catch (_) {
          coverPath = null;
        }
      }
      final downloadedAt = DateTime.now().toUtc();
      final manifest = File(p.join(directory.path, 'manifest.json'));
      final partialManifest = File('${manifest.path}.part');
      await partialManifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'version': 1,
          'server_id': server.id,
          'server_name': server.name,
          'library_id': library.id,
          'library_name': library.name,
          'work_id': work.id,
          'title': work.title,
          'kind': work.kind,
          'authors': work.authors,
          if (work.subtitle != null) 'subtitle': work.subtitle,
          if (work.series != null) 'series': work.series,
          if (work.seriesSequence != null)
            'series_sequence': work.seriesSequence,
          'narrators': work.narrators,
          if (work.language != null) 'language': work.language,
          if (work.description != null) 'description': work.description,
          if (work.publisher != null) 'publisher': work.publisher,
          if (work.publishedYear != null) 'published_year': work.publishedYear,
          'tags': work.tags,
          'downloaded_at': downloadedAt.toIso8601String(),
          if (coverPath != null) 'cover_path': p.basename(coverPath),
          'tracks': [
            for (final track in offlineTracks)
              {
                'id': track.id,
                'title': track.title,
                'path': p.basename(track.path),
                'position': track.position,
                if (track.duration != null)
                  'duration_ms': track.duration!.inMilliseconds,
                if (track.audioMetadata != null)
                  'audio': {
                    'container': track.audioMetadata!.container,
                    'codec': track.audioMetadata!.codec,
                    'profile': track.audioMetadata!.profile,
                    'channels': track.audioMetadata!.channels,
                    'sample_rate_hz': track.audioMetadata!.sampleRateHz,
                  },
              },
          ],
          'chapters': [
            for (final chapter in detail.chapters)
              {
                'title': chapter.title,
                'file_id': chapter.fileId,
                'track_index': chapter.trackIndex,
                'position_ms': chapter.position.inMilliseconds,
                if (chapter.duration != null)
                  'duration_ms': chapter.duration!.inMilliseconds,
              },
          ],
        }),
        flush: true,
      );
      if (await manifest.exists()) await manifest.delete();
      await partialManifest.rename(manifest.path);
      try {
        final progress = await client.progress(server, library.id, work.id);
        if (progress != null) {
          await cacheProgress(
            serverId: server.id,
            libraryId: library.id,
            workId: work.id,
            progress: progress,
          );
        }
      } catch (_) {
        // Der Download bleibt auch ohne erreichbaren Fortschritts-Endpunkt
        // vollständig offline nutzbar.
      }
      final result = (await lookup(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
      ))!;
      await _appendLedger('downloaded', {
        'server_id': server.id,
        'library_id': library.id,
        'work_id': work.id,
        'title': work.title,
        'file_count': result.tracks.length,
      });
      return result;
    } catch (_) {
      for (final entity in directory.listSync().whereType<File>()) {
        if (entity.path.endsWith('.part')) await entity.delete();
      }
      rethrow;
    }
  }

  static AudioTechnicalMetadata? _audioMetadata(Object? value) {
    if (value is! Map ||
        value['container'] is! String ||
        value['codec'] is! String) {
      return null;
    }
    return AudioTechnicalMetadata(
      container: value['container'] as String,
      codec: value['codec'] as String,
      profile: value['profile'] as String?,
      channels: value['channels'] as int?,
      sampleRateHz: value['sample_rate_hz'] as int?,
    );
  }

  Future<void> remove({
    required String serverId,
    required String libraryId,
    required String workId,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, workId);
    if (await directory.exists()) await directory.delete(recursive: true);
    for (final fallback in _fallbacks) {
      await fallback.remove(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
      );
    }
    await _appendLedger('removed', {
      'server_id': serverId,
      'library_id': libraryId,
      'work_id': workId,
    });
  }

  Future<FundusRemoteProgress?> loadProgress({
    required String serverId,
    required String libraryId,
    required String workId,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, workId);
    final file = File(p.join(directory.path, 'progress.json'));
    if (!await file.exists()) {
      for (final fallback in _fallbacks) {
        final progress = await fallback.loadProgress(
          serverId: serverId,
          libraryId: libraryId,
          workId: workId,
        );
        if (progress != null) return progress;
      }
      return null;
    }
    return _loadProgressFromDirectory(directory);
  }

  Future<WorkAnnotations> loadAnnotations({
    required String serverId,
    required String libraryId,
    required String workId,
  }) async {
    final fallback = await _fallbackContaining(serverId, libraryId, workId);
    if (fallback != null) {
      return fallback.loadAnnotations(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
      );
    }
    final directory = await _workDirectory(serverId, libraryId, workId);
    final file = File(p.join(directory.path, 'annotations.json'));
    if (!await file.exists()) return const WorkAnnotations();
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return const WorkAnnotations();
      final bookmarks = <LibraryBookmark>[];
      for (final item
          in (value['bookmarks'] as List? ?? const []).whereType<Map>()) {
        final position = item['position'];
        if (item['id'] is! String || position is! Map) continue;
        final mediaPosition = _mediaPosition(position);
        if (mediaPosition == null) continue;
        bookmarks.add(
          LibraryBookmark(
            id: item['id'] as String,
            workId: workId,
            fileId: item['file_id'] as String?,
            mediaPosition: mediaPosition,
            label: item['label'] as String?,
            note: item['note'] as String?,
            createdAt:
                DateTime.tryParse('${item['created_at'] ?? ''}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      }
      final highlights = <LibraryHighlight>[];
      for (final item
          in (value['highlights'] as List? ?? const []).whereType<Map>()) {
        final position = item['position'];
        if (item['id'] is! String ||
            item['quote'] is! String ||
            position is! Map) {
          continue;
        }
        final mediaPosition = _mediaPosition(position);
        if (mediaPosition == null) continue;
        highlights.add(
          LibraryHighlight(
            id: item['id'] as String,
            workId: workId,
            fileId: item['file_id'] as String?,
            mediaPosition: mediaPosition,
            quote: item['quote'] as String,
            color: item['color'] is String
                ? item['color'] as String
                : '#FFF176',
            note: item['note'] as String?,
            createdAt:
                DateTime.tryParse('${item['created_at'] ?? ''}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      }
      final notes = <LibraryNote>[];
      for (final item
          in (value['notes'] as List? ?? const []).whereType<Map>()) {
        if (item['id'] is! String || item['markdown'] is! String) continue;
        notes.add(
          LibraryNote(
            id: item['id'] as String,
            markdown: item['markdown'] as String,
            createdAt:
                DateTime.tryParse('${item['created_at'] ?? ''}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      }
      return WorkAnnotations(
        tags: (value['tags'] as List? ?? const []).whereType<String>().toList(),
        notes: notes,
        bookmarks: bookmarks,
        highlights: highlights,
      );
    } on FileSystemException {
      return const WorkAnnotations();
    } on FormatException {
      return const WorkAnnotations();
    }
  }

  Future<WorkAnnotations> addMediaBookmark({
    required String serverId,
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    String? label,
  }) async {
    final annotations = await loadAnnotations(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
    );
    final updated = WorkAnnotations(
      tags: annotations.tags,
      notes: annotations.notes,
      bookmarks: [
        ...annotations.bookmarks,
        LibraryBookmark(
          id: FundusId.generate(),
          workId: workId,
          fileId: fileId,
          mediaPosition: position,
          label: label?.trim().isEmpty ?? true ? null : label!.trim(),
          createdAt: DateTime.now(),
        ),
      ],
      highlights: annotations.highlights,
    );
    await _saveAnnotations(serverId, libraryId, workId, updated);
    return updated;
  }

  Future<WorkAnnotations> addTextHighlight({
    required String serverId,
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    required String quote,
    required String color,
    String? note,
  }) async {
    final annotations = await loadAnnotations(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
    );
    final updated = WorkAnnotations(
      tags: annotations.tags,
      notes: annotations.notes,
      bookmarks: annotations.bookmarks,
      highlights: [
        ...annotations.highlights,
        LibraryHighlight(
          id: FundusId.generate(),
          workId: workId,
          fileId: fileId,
          mediaPosition: position,
          quote: quote.trim(),
          color: color,
          note: note?.trim().isEmpty ?? true ? null : note!.trim(),
          createdAt: DateTime.now(),
        ),
      ],
    );
    await _saveAnnotations(serverId, libraryId, workId, updated);
    return updated;
  }

  Future<WorkAnnotations> deleteAnnotation({
    required String serverId,
    required String libraryId,
    required String workId,
    required String annotationId,
  }) async {
    final annotations = await loadAnnotations(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
    );
    final updated = WorkAnnotations(
      tags: annotations.tags,
      notes: annotations.notes,
      bookmarks: annotations.bookmarks
          .where((item) => item.id != annotationId)
          .toList(growable: false),
      highlights: annotations.highlights
          .where((item) => item.id != annotationId)
          .toList(growable: false),
    );
    await _saveAnnotations(serverId, libraryId, workId, updated);
    return updated;
  }

  Future<WorkAnnotations> saveWorkNote({
    required String serverId,
    required String libraryId,
    required String workId,
    required String markdown,
  }) async {
    final normalized = markdown.trim();
    final annotations = await loadAnnotations(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
    );
    if (normalized.isEmpty) return annotations;
    final updated = WorkAnnotations(
      tags: annotations.tags,
      notes: [
        ...annotations.notes,
        LibraryNote(
          id: FundusId.generate(),
          markdown: normalized,
          createdAt: DateTime.now(),
        ),
      ],
      bookmarks: annotations.bookmarks,
      highlights: annotations.highlights,
    );
    await _saveAnnotations(serverId, libraryId, workId, updated);
    return updated;
  }

  Future<WorkAnnotations> replaceWorkTags({
    required String serverId,
    required String libraryId,
    required String workId,
    required Iterable<String> tags,
  }) async {
    final annotations = await loadAnnotations(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
    );
    final updated = WorkAnnotations(
      tags: tags.toSet().toList()..sort(),
      notes: annotations.notes,
      bookmarks: annotations.bookmarks,
      highlights: annotations.highlights,
    );
    await _saveAnnotations(serverId, libraryId, workId, updated);
    return updated;
  }

  Future<void> cacheAnnotations({
    required String serverId,
    required String libraryId,
    required String workId,
    required WorkAnnotations annotations,
  }) => _saveAnnotations(serverId, libraryId, workId, annotations);

  Future<void> _saveAnnotations(
    String serverId,
    String libraryId,
    String workId,
    WorkAnnotations annotations,
  ) async {
    final fallback = await _fallbackContaining(serverId, libraryId, workId);
    if (fallback != null) {
      await fallback._saveAnnotations(serverId, libraryId, workId, annotations);
      return;
    }
    final directory = await _workDirectory(serverId, libraryId, workId);
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, 'annotations.json'));
    final partial = File('${destination.path}.part');
    await partial.writeAsString(
      jsonEncode({
        'format_version': 1,
        'tags': annotations.tags,
        'notes': [
          for (final item in annotations.notes)
            {
              'id': item.id,
              'markdown': item.markdown,
              'created_at': item.createdAt.toUtc().toIso8601String(),
            },
        ],
        'bookmarks': [
          for (final item in annotations.bookmarks)
            {
              'id': item.id,
              'file_id': item.fileId,
              'position': item.mediaPosition.toJson(),
              'label': item.label,
              'note': item.note,
              'created_at': item.createdAt.toUtc().toIso8601String(),
            },
        ],
        'highlights': [
          for (final item in annotations.highlights)
            {
              'id': item.id,
              'file_id': item.fileId,
              'position': item.mediaPosition.toJson(),
              'quote': item.quote,
              'color': item.color,
              'note': item.note,
              'created_at': item.createdAt.toUtc().toIso8601String(),
            },
        ],
      }),
      flush: true,
    );
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
  }

  Future<FundusRemoteProgress?> _loadProgressFromDirectory(
    Directory directory,
  ) async {
    final file = File(p.join(directory.path, 'progress.json'));
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map) return null;
      return FundusRemoteProgress(
        fileId: value['file_id'] is String ? value['file_id'] as String : null,
        position: Duration(
          milliseconds: value['position_ms'] is int
              ? value['position_ms'] as int
              : 0,
        ),
        finished: value['finished'] == true,
        revision: value['revision'] is int ? value['revision'] as int : 0,
        mediaPosition: value['position'] is Map
            ? _mediaPosition(value['position'] as Map)
            : null,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> cacheProgress({
    required String serverId,
    required String libraryId,
    required String workId,
    required FundusRemoteProgress progress,
  }) async {
    final fallback = await _fallbackContaining(serverId, libraryId, workId);
    if (fallback != null) {
      await fallback.cacheProgress(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        progress: progress,
      );
      return;
    }
    final directory = await _workDirectory(serverId, libraryId, workId);
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, 'progress.json'));
    if (await destination.exists()) {
      try {
        final current = jsonDecode(await destination.readAsString());
        if (current is Map && current['pending_sync'] == true) return;
      } on FormatException {
        // Eine defekte Cache-Datei wird unten atomar ersetzt.
      }
    }
    final partial = File('${destination.path}.part');
    await partial.writeAsString(
      jsonEncode({
        'file_id': progress.fileId,
        'position_ms': progress.position.inMilliseconds,
        if (progress.mediaPosition != null)
          'position': progress.mediaPosition!.toJson(),
        'finished': progress.finished,
        'revision': progress.revision,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'pending_sync': false,
      }),
      flush: true,
    );
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
  }

  Future<FundusOfflinePendingProgress> saveProgress({
    required String serverId,
    required String libraryId,
    required String workId,
    required String fileId,
    required Duration position,
    required bool finished,
  }) async {
    final fallback = await _fallbackContaining(serverId, libraryId, workId);
    if (fallback != null) {
      return fallback.saveProgress(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        fileId: fileId,
        position: position,
        finished: finished,
      );
    }
    final directory = await _workDirectory(serverId, libraryId, workId);
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, 'progress.json'));
    final partial = File('${destination.path}.part');
    final updatedAt = DateTime.now().toUtc().toIso8601String();
    final operationId = sha256
        .convert(
          utf8.encode(
            '$serverId\u0000$libraryId\u0000$workId\u0000$fileId\u0000'
            '${position.inMilliseconds}\u0000$updatedAt',
          ),
        )
        .toString();
    await partial.writeAsString(
      jsonEncode({
        'file_id': fileId,
        'position_ms': position.inMilliseconds,
        'finished': finished,
        'updated_at': updatedAt,
        'operation_id': 'offline-$operationId',
        'pending_sync': true,
      }),
      flush: true,
    );
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
    return FundusOfflinePendingProgress(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
      fileId: fileId,
      position: position,
      finished: finished,
      operationId: 'offline-$operationId',
    );
  }

  Future<FundusOfflinePendingProgress> saveMediaProgress({
    required String serverId,
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    required bool finished,
  }) async {
    final fallback = await _fallbackContaining(serverId, libraryId, workId);
    if (fallback != null) {
      return fallback.saveMediaProgress(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        fileId: fileId,
        position: position,
        finished: finished,
      );
    }
    final directory = await _workDirectory(serverId, libraryId, workId);
    await directory.create(recursive: true);
    final destination = File(p.join(directory.path, 'progress.json'));
    final partial = File('${destination.path}.part');
    final updatedAt = DateTime.now().toUtc().toIso8601String();
    final operationId = sha256
        .convert(
          utf8.encode(
            '$serverId\u0000$libraryId\u0000$workId\u0000$fileId\u0000'
            '${jsonEncode(position.toJson())}\u0000$updatedAt',
          ),
        )
        .toString();
    await partial.writeAsString(
      jsonEncode({
        'file_id': fileId,
        'position': position.toJson(),
        'finished': finished,
        'updated_at': updatedAt,
        'operation_id': 'offline-$operationId',
        'pending_sync': true,
      }),
      flush: true,
    );
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
    return FundusOfflinePendingProgress(
      serverId: serverId,
      libraryId: libraryId,
      workId: workId,
      fileId: fileId,
      position: Duration.zero,
      mediaPosition: position,
      finished: finished,
      operationId: 'offline-$operationId',
    );
  }

  Future<List<FundusOfflinePendingProgress>> pendingProgress() async {
    final byOperation = <String, FundusOfflinePendingProgress>{};
    for (final work in await listAll()) {
      final directory = await _workDirectory(
        work.serverId,
        work.libraryId,
        work.workId,
      );
      final file = File(p.join(directory.path, 'progress.json'));
      if (!await file.exists()) continue;
      try {
        final value = jsonDecode(await file.readAsString());
        if (value is! Map ||
            value['pending_sync'] != true ||
            value['file_id'] is! String ||
            value['operation_id'] is! String) {
          continue;
        }
        final pending = FundusOfflinePendingProgress(
          serverId: work.serverId,
          libraryId: work.libraryId,
          workId: work.workId,
          fileId: value['file_id'] as String,
          position: Duration(
            milliseconds: value['position_ms'] is int
                ? value['position_ms'] as int
                : 0,
          ),
          finished: value['finished'] == true,
          operationId: value['operation_id'] as String,
          mediaPosition: value['position'] is Map
              ? _mediaPosition(value['position'] as Map)
              : null,
        );
        byOperation[pending.operationId] = pending;
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    for (final fallback in _fallbacks) {
      for (final pending in await fallback.pendingProgress()) {
        byOperation.putIfAbsent(pending.operationId, () => pending);
      }
    }
    return byOperation.values.toList(growable: false);
  }

  Future<void> markProgressSynced(FundusOfflinePendingProgress pending) async {
    final directory = await _workDirectory(
      pending.serverId,
      pending.libraryId,
      pending.workId,
    );
    final destination = File(p.join(directory.path, 'progress.json'));
    if (!await destination.exists()) {
      for (final fallback in _fallbacks) {
        await fallback.markProgressSynced(pending);
      }
      return;
    }
    try {
      final value = jsonDecode(await destination.readAsString());
      if (value is! Map || value['operation_id'] != pending.operationId) return;
      final partial = File('${destination.path}.part');
      await partial.writeAsString(
        jsonEncode({...value, 'pending_sync': false}),
        flush: true,
      );
      await destination.delete();
      await partial.rename(destination.path);
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
  }

  Future<Directory> _workDirectory(
    String serverId,
    String libraryId,
    String workId,
  ) async {
    final root = await _root();
    final key = sha256
        .convert(utf8.encode('$serverId\u0000$libraryId\u0000$workId'))
        .toString();
    return Directory(p.join(root.path, key));
  }

  Future<FundusOfflineStore?> _fallbackContaining(
    String serverId,
    String libraryId,
    String workId,
  ) async {
    final primary = await _workDirectory(serverId, libraryId, workId);
    if (await File(p.join(primary.path, 'manifest.json')).exists()) return null;
    for (final fallback in _fallbacks) {
      if (await fallback.lookup(
            serverId: serverId,
            libraryId: libraryId,
            workId: workId,
          ) !=
          null) {
        return fallback;
      }
    }
    return null;
  }

  static String _extension(String title) {
    final extension = p.extension(title).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(extension)
        ? extension
        : '.bin';
  }

  static MediaPosition? _mediaPosition(Map value) {
    try {
      return MediaPosition.fromJson(Map<String, Object?>.from(value));
    } on Object {
      return null;
    }
  }

  static String _workKey(FundusOfflineWork work) =>
      '${work.serverId}\u0000${work.libraryId}\u0000${work.workId}';

  Future<void> _appendLedger(String event, Map<String, Object?> details) async {
    try {
      final root = await _root();
      await root.create(recursive: true);
      final file = File(p.join(root.path, 'downloads.log'));
      await file.writeAsString(
        '${jsonEncode({'timestamp': DateTime.now().toUtc().toIso8601String(), 'event': event, ...details})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on FileSystemException {
      // Ein optionales Verwaltungsprotokoll darf Downloads nicht blockieren.
    }
  }
}
