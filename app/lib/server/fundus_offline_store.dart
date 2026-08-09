import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
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
  });

  final String id;
  final String title;
  final String path;
  final int position;
  final Duration? duration;
}

final class FundusOfflineWork {
  const FundusOfflineWork({
    required this.serverId,
    required this.libraryId,
    required this.workId,
    required this.title,
    required this.downloadedAt,
    required this.tracks,
    this.kind = 'audiobook',
    this.authors = const [],
    this.series,
    this.description,
    this.coverPath,
  });

  final String serverId;
  final String libraryId;
  final String workId;
  final String title;
  final DateTime downloadedAt;
  final List<FundusOfflineTrack> tracks;
  final String kind;
  final List<String> authors;
  final String? series;
  final String? description;
  final String? coverPath;
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
  });

  final String serverId;
  final String libraryId;
  final String workId;
  final String fileId;
  final Duration position;
  final bool finished;
  final String operationId;
}

typedef OfflineDownloadProgress = void Function(int completed, int total);

final class FundusOfflineStore {
  FundusOfflineStore({Directory? root}) : _configuredRoot = root;

  final Directory? _configuredRoot;

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
    if (!await manifest.exists()) return null;
    try {
      final value = jsonDecode(await manifest.readAsString());
      if (value is! Map) return null;
      final tracksValue = value['tracks'];
      if (tracksValue is! List) return null;
      final tracks = <FundusOfflineTrack>[];
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
          return null;
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
          ),
        );
      }
      if (tracks.isEmpty) return null;
      tracks.sort((a, b) => a.position.compareTo(b.position));
      final coverValue = value['cover_path'];
      final coverPath = coverValue is String
          ? p.normalize(p.join(directory.path, coverValue))
          : null;
      return FundusOfflineWork(
        serverId: serverId,
        libraryId: libraryId,
        workId: workId,
        title: value['title'] is String ? value['title'] as String : 'Medium',
        kind: value['kind'] is String ? value['kind'] as String : 'audiobook',
        authors: (value['authors'] as List? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        series: value['series'] is String ? value['series'] as String : null,
        description: value['description'] is String
            ? value['description'] as String
            : null,
        downloadedAt:
            DateTime.tryParse('${value['downloaded_at'] ?? ''}') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        tracks: tracks,
        coverPath:
            coverPath != null &&
                p.isWithin(directory.path, coverPath) &&
                await File(coverPath).exists()
            ? coverPath
            : null,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<List<FundusOfflineWork>> listAll() async {
    final root = await _root();
    if (!await root.exists()) return const [];
    final result = <FundusOfflineWork>[];
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
        if (work != null) result.add(work);
      } on FormatException {
        continue;
      } on FileSystemException {
        continue;
      }
    }
    result.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return result;
  }

  Future<FundusOfflineWork> download(
    FundusRemoteClient client,
    FundusRemoteServer server,
    FundusRemoteLibrary library,
    FundusRemoteWork work, {
    OfflineDownloadProgress? onProgress,
  }) async {
    final detail = await client.work(server, library.id, work);
    if (detail.tracks.isEmpty) {
      throw StateError('Dieses Werk enthält keine herunterladbaren Dateien.');
    }
    final directory = await _workDirectory(server.id, library.id, work.id);
    await directory.create(recursive: true);
    final offlineTracks = <FundusOfflineTrack>[];
    var completed = 0;
    onProgress?.call(completed, detail.tracks.length);
    try {
      for (var index = 0; index < detail.tracks.length; index++) {
        final track = detail.tracks[index];
        final filename =
            '${index.toString().padLeft(4, '0')}${_extension(track.title)}';
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
          await sink.addStream(remote.response);
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
          ),
        );
        completed++;
        onProgress?.call(completed, detail.tracks.length);
      }
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
          'library_id': library.id,
          'work_id': work.id,
          'title': work.title,
          'kind': work.kind,
          'authors': work.authors,
          if (work.series != null) 'series': work.series,
          if (work.description != null) 'description': work.description,
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
              },
          ],
        }),
        flush: true,
      );
      if (await manifest.exists()) await manifest.delete();
      await partialManifest.rename(manifest.path);
      return (await lookup(
        serverId: server.id,
        libraryId: library.id,
        workId: work.id,
      ))!;
    } catch (_) {
      for (final entity in directory.listSync().whereType<File>()) {
        if (entity.path.endsWith('.part')) await entity.delete();
      }
      rethrow;
    }
  }

  Future<void> remove({
    required String serverId,
    required String libraryId,
    required String workId,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, workId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<FundusRemoteProgress?> loadProgress({
    required String serverId,
    required String libraryId,
    required String workId,
  }) async {
    final directory = await _workDirectory(serverId, libraryId, workId);
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
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<FundusOfflinePendingProgress> saveProgress({
    required String serverId,
    required String libraryId,
    required String workId,
    required String fileId,
    required Duration position,
    required bool finished,
  }) async {
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

  Future<List<FundusOfflinePendingProgress>> pendingProgress() async {
    final result = <FundusOfflinePendingProgress>[];
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
        result.add(
          FundusOfflinePendingProgress(
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
          ),
        );
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  Future<void> markProgressSynced(FundusOfflinePendingProgress pending) async {
    final directory = await _workDirectory(
      pending.serverId,
      pending.libraryId,
      pending.workId,
    );
    final destination = File(p.join(directory.path, 'progress.json'));
    if (!await destination.exists()) return;
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

  static String _extension(String title) {
    final extension = p.extension(title).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(extension)
        ? extension
        : '.bin';
  }
}
