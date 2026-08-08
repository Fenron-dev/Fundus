import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/fundus_database.dart';
import '../import/abs_importer.dart';
import '../import/embedded_cover.dart';
import '../model/fundus_id.dart';
import '../model/library_manifest.dart';
import '../playback/library_playback.dart';
import '../scan/library_scanner.dart';
import '../search/library_work_query.dart';

enum LibraryIndexPhase { scanning, importing, completed, cancelled }

final class LibraryIndexEvent {
  const LibraryIndexEvent({
    required this.phase,
    required this.fileCount,
    this.workCount = 0,
    this.currentPath,
  });

  final LibraryIndexPhase phase;
  final int fileCount;
  final int workCount;
  final String? currentPath;
}

final class FundusLibrary {
  FundusLibrary._({
    required this.root,
    required this.manifest,
    required this.openMode,
    required FundusDatabase database,
  }) : _database = database;

  static const metadataDirectoryName = '.library';
  static const manifestFileName = 'version.json';
  static const databaseFileName = 'index.db';

  final Directory root;
  final LibraryManifest manifest;
  final LibraryOpenMode openMode;
  final FundusDatabase _database;

  bool get isReadOnly => openMode != LibraryOpenMode.readWrite;

  static Future<FundusLibrary> create(
    Directory root, {
    String createdBy = 'Fundus',
  }) async {
    await root.create(recursive: true);
    final manifestFile = _manifestFile(root);
    if (await manifestFile.exists()) return open(root);
    final manifest = LibraryManifest(
      libraryId: FundusId.generate(),
      formatVersion: LibraryManifest.currentFormatVersion,
      minReaderVersion: LibraryManifest.currentReaderVersion,
      createdBy: createdBy,
    );
    await manifest.write(manifestFile);
    return FundusLibrary._(
      root: root.absolute,
      manifest: manifest,
      openMode: LibraryOpenMode.readWrite,
      database: FundusDatabase.openFile(_databaseFile(root)),
    );
  }

  static Future<FundusLibrary> open(Directory root) async {
    final manifestFile = _manifestFile(root);
    if (!await manifestFile.exists()) {
      throw FileSystemException(
        'In diesem Ordner wurde keine Fundus-Bibliothek gefunden.',
        root.path,
      );
    }
    final manifest = await LibraryManifest.read(manifestFile);
    final compatibility = manifest.compatibility();
    if (compatibility.mode == LibraryOpenMode.incompatible) {
      throw StateError(compatibility.message);
    }
    return FundusLibrary._(
      root: root.absolute,
      manifest: manifest,
      openMode: compatibility.mode,
      database: FundusDatabase.openFile(
        _databaseFile(root),
        readOnly: compatibility.mode == LibraryOpenMode.readOnly,
      ),
    );
  }

  List<LibraryWorkSummary> listWorks() =>
      _database.listWorks().map(_withAbsoluteCoverPath).toList(growable: false);

  List<LibraryWorkSummary> searchWorks([
    LibraryWorkQuery query = const LibraryWorkQuery(),
  ]) => LibraryWorkSearch.apply(listWorks(), query);

  List<LibraryPlaybackTrack> playbackTracks(String workId) {
    return _database
        .playbackTracks(workId)
        .map((track) {
          final absolutePath = p.normalize(p.join(root.path, track.path));
          if (!p.isWithin(root.path, absolutePath)) {
            throw StateError(
              'Unsicherer Medienpfad im Bibliotheksindex: ${track.path}',
            );
          }
          return LibraryPlaybackTrack(
            fileId: track.fileId,
            relativePath: track.path,
            absolutePath: absolutePath,
            title: track.title,
            index: track.position,
            duration: track.durationMs == null
                ? null
                : Duration(milliseconds: track.durationMs!),
          );
        })
        .toList(growable: false);
  }

  LibraryPlaybackProgress? loadProgress(String workId) =>
      _database.loadProgress(workId);

  LibraryPlaybackProgress saveProgress({
    required String workId,
    required String fileId,
    required Duration position,
    Duration? duration,
    bool finished = false,
    String deviceId = 'desktop-local',
    String? operationId,
  }) => _database.saveProgress(
    workId: workId,
    fileId: fileId,
    position: position,
    duration: duration,
    finished: finished,
    deviceId: deviceId,
    operationId: operationId ?? FundusId.generate(),
  );

  Stream<LibraryIndexEvent> index({
    LibraryScanner? scanner,
    AbsImporter? importer,
    ScanCancellationToken? cancellationToken,
  }) async* {
    if (isReadOnly) {
      throw StateError('Die Bibliothek ist schreibgeschützt.');
    }
    final files = <ScannedFile>[];
    await for (final event in (scanner ?? LibraryScanner()).scan(
      root,
      cancellationToken: cancellationToken,
    )) {
      if (event.kind == ScanEventKind.file) files.add(event.file!);
      if (event.kind == ScanEventKind.cancelled) {
        yield LibraryIndexEvent(
          phase: LibraryIndexPhase.cancelled,
          fileCount: files.length,
        );
        return;
      }
      if (event.kind == ScanEventKind.file ||
          event.kind == ScanEventKind.started) {
        yield LibraryIndexEvent(
          phase: LibraryIndexPhase.scanning,
          fileCount: files.length,
          currentPath: event.file?.relativePath,
        );
      }
    }

    final candidates = (importer ?? AbsImporter()).group(files);
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.importing,
      fileCount: files.length,
      workCount: candidates.length,
    );
    final indexedCandidates = _database.transaction(() {
      final ids = <String, String>{};
      final indexed = <({AudiobookImportCandidate candidate, String workId})>[];
      for (final file in files) {
        ids[file.relativePath] = _database.upsertFile(file);
      }
      _database.markUnseenFilesMissing(ids.keys.toSet());
      for (final candidate in candidates) {
        indexed.add((
          candidate: candidate,
          workId: _database.upsertAudiobookCandidate(candidate, ids),
        ));
      }
      return indexed;
    });
    for (final indexed in indexedCandidates) {
      await _cacheEmbeddedCover(indexed.candidate, indexed.workId);
    }
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.completed,
      fileCount: files.length,
      workCount: candidates.length,
    );
  }

  void close() => _database.close();

  LibraryWorkSummary _withAbsoluteCoverPath(LibraryWorkSummary work) {
    final coverPath = work.coverPath;
    if (coverPath == null) return work;
    final absolutePath = p.normalize(p.join(root.path, coverPath));
    if (!p.isWithin(root.path, absolutePath)) return work;
    return LibraryWorkSummary(
      id: work.id,
      kind: work.kind,
      title: work.title,
      author: work.author,
      fileCount: work.fileCount,
      addedAt: work.addedAt,
      series: work.series,
      seriesSequence: work.seriesSequence,
      coverPath: absolutePath,
    );
  }

  Future<void> _cacheEmbeddedCover(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    if (candidate.coverFiles.isNotEmpty) {
      _database.setGeneratedCoverPath(workId, null);
      return;
    }
    final coverDirectory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    for (final extension in const ['jpg', 'png']) {
      final existing = File(p.join(coverDirectory.path, '$workId.$extension'));
      if (await existing.exists()) {
        _database.setGeneratedCoverPath(
          workId,
          p.posix.join(metadataDirectoryName, 'covers', '$workId.$extension'),
        );
        return;
      }
    }

    const extractor = EmbeddedCoverExtractor();
    for (final audio in candidate.audioFiles) {
      try {
        final cover = await extractor.extract(File(audio.absolutePath));
        if (cover == null) continue;
        await coverDirectory.create(recursive: true);
        final filename = '$workId.${cover.extension}';
        await File(
          p.join(coverDirectory.path, filename),
        ).writeAsBytes(cover.bytes, flush: true);
        _database.setGeneratedCoverPath(
          workId,
          p.posix.join(metadataDirectoryName, 'covers', filename),
        );
        return;
      } on FileSystemException {
        // A single unreadable media file must not abort the complete scan.
      } on FormatException {
        // Invalid embedded metadata falls back to the placeholder artwork.
      }
    }
    _database.setGeneratedCoverPath(workId, null);
  }

  static File _manifestFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$manifestFileName');

  static File _databaseFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$databaseFileName');
}
