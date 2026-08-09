import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../database/fundus_database.dart';
import '../import/abs_importer.dart';
import '../import/embedded_cover.dart';
import '../model/fundus_id.dart';
import '../model/library_manifest.dart';
import '../playback/library_playback.dart';
import '../scan/library_scanner.dart';
import '../search/library_work_query.dart';
import 'work_annotations.dart';

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

  WorkAnnotations loadAnnotations(String workId) =>
      _database.loadAnnotations(workId);

  List<String> listTags() => _database.listTags();

  Future<WorkAnnotations> replaceWorkTags(
    String workId,
    Iterable<String> tags,
  ) async {
    _ensureWritable();
    _database.replaceWorkTags(workId, tags);
    await _writeAnnotationSidecars(workId);
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> saveWorkNote(String workId, String markdown) async {
    _ensureWritable();
    _database.saveWorkNote(workId, markdown);
    await _writeAnnotationSidecars(workId);
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> addBookmark({
    required String workId,
    required String fileId,
    required Duration position,
    String? label,
    String? note,
  }) async {
    _ensureWritable();
    _database.addBookmark(
      workId: workId,
      fileId: fileId,
      position: position,
      label: label,
      note: note,
    );
    await _writeAnnotationSidecars(workId);
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> deleteBookmark(
    String workId,
    String bookmarkId,
  ) async {
    _ensureWritable();
    _database.deleteBookmark(bookmarkId);
    await _writeAnnotationSidecars(workId);
    return loadAnnotations(workId);
  }

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
      try {
        await _importLanguage(indexed.candidate, indexed.workId);
      } on FileSystemException {
        // A broken metadata source must not hide the complete library.
      } on YamlException {
        // The user can repair malformed language metadata and scan again.
      } on FormatException {
        // Invalid source JSON is ignored until repaired.
      }
      try {
        await _importAnnotationSidecars(indexed.candidate, indexed.workId);
      } on FileSystemException {
        // A broken sidecar must not make the complete library unavailable.
      } on YamlException {
        // The user can repair malformed portable metadata and scan again.
      }
      await _cacheEmbeddedCover(indexed.candidate, indexed.workId);
    }
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.completed,
      fileCount: files.length,
      workCount: candidates.length,
    );
  }

  void close() => _database.close();

  void _ensureWritable() {
    if (isReadOnly) {
      throw StateError('Die Bibliothek ist schreibgeschützt.');
    }
  }

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
      language: work.language,
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

  Future<void> _writeAnnotationSidecars(String workId) async {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return;
    final workDirectory = _safeWorkDirectory(sourcePath);
    final sidecarDirectory = Directory(p.join(workDirectory.path, '_fundus'));
    await sidecarDirectory.create(recursive: true);
    final annotations = loadAnnotations(workId);
    await File(
      p.join(sidecarDirectory.path, 'notes.md'),
    ).writeAsString(annotations.note, flush: true);
    await File(p.join(sidecarDirectory.path, 'meta.yaml')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format_version': 1,
        'language': _database.workLanguage(workId),
        'tags': annotations.tags,
      }),
      flush: true,
    );
    final tracksById = {
      for (final track in playbackTracks(workId))
        track.fileId: track.relativePath,
    };
    await File(p.join(sidecarDirectory.path, 'bookmarks.yaml')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format_version': 1,
        'bookmarks': [
          for (final bookmark in annotations.bookmarks)
            {
              'id': bookmark.id,
              'file_path': tracksById[bookmark.fileId],
              'position_ms': bookmark.position.inMilliseconds,
              'label': bookmark.label,
              'note': bookmark.note,
              'created_at': bookmark.createdAt.toUtc().toIso8601String(),
            },
        ],
      }),
      flush: true,
    );
  }

  Future<void> _importAnnotationSidecars(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final sidecarDirectory = Directory(
      p.joinAll([root.path, ...p.posix.split(candidate.directory), '_fundus']),
    );
    if (!await sidecarDirectory.exists()) return;
    var annotations = loadAnnotations(workId);
    final noteFile = File(p.join(sidecarDirectory.path, 'notes.md'));
    if (annotations.note.isEmpty && await noteFile.exists()) {
      _database.saveWorkNote(
        workId,
        await noteFile.readAsString(),
        updatedAt: await noteFile.lastModified(),
      );
    }
    final metaFile = File(p.join(sidecarDirectory.path, 'meta.yaml'));
    if (annotations.tags.isEmpty && await metaFile.exists()) {
      final value = loadYaml(await metaFile.readAsString());
      if (value is Map && value['tags'] is List) {
        _database.replaceWorkTags(
          workId,
          (value['tags'] as List).whereType<String>(),
        );
      }
    }
    annotations = loadAnnotations(workId);
    final bookmarksFile = File(p.join(sidecarDirectory.path, 'bookmarks.yaml'));
    if (annotations.bookmarks.isEmpty && await bookmarksFile.exists()) {
      final value = loadYaml(await bookmarksFile.readAsString());
      final bookmarks = value is Map ? value['bookmarks'] : null;
      if (bookmarks is List) {
        final tracksByPath = {
          for (final track in playbackTracks(workId))
            track.relativePath: track.fileId,
        };
        for (final item in bookmarks.whereType<Map>()) {
          final fileId = tracksByPath[item['file_path']];
          final positionMs = item['position_ms'];
          if (fileId == null || positionMs is! num) continue;
          final id = item['id'];
          final label = item['label'];
          final note = item['note'];
          final createdAt = item['created_at'];
          _database.addBookmark(
            id: id is String ? id : null,
            workId: workId,
            fileId: fileId,
            position: Duration(milliseconds: positionMs.round()),
            label: label is String ? label : null,
            note: note is String ? note : null,
            createdAt: createdAt is String
                ? DateTime.tryParse(createdAt)
                : null,
          );
        }
      }
    }
  }

  Future<void> _importLanguage(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final workDirectory = _safeWorkDirectory(candidate.directory);
    final fundusMeta = File(p.join(workDirectory.path, '_fundus', 'meta.yaml'));
    if (await fundusMeta.exists()) {
      final value = loadYaml(await fundusMeta.readAsString());
      if (value is Map && value['language'] is String) {
        _database.setWorkLanguage(workId, value['language'] as String);
        return;
      }
    }

    final sourceFile = File(p.join(workDirectory.path, '_source.json'));
    if (await sourceFile.exists()) {
      final value = jsonDecode(await sourceFile.readAsString());
      if (value is Map) {
        final direct = value['language'];
        final metadata = value['metadata'];
        final nested = metadata is Map ? metadata['language'] : null;
        final language = direct is String
            ? direct
            : nested is String
            ? nested
            : null;
        if (language != null && language.trim().isNotEmpty) {
          _database.setWorkLanguage(workId, language);
          return;
        }
      }
    }

    const extractor = EmbeddedCoverExtractor();
    for (final audio in candidate.audioFiles) {
      final language = await extractor.extractLanguage(
        File(audio.absolutePath),
      );
      if (language == null || language.trim().isEmpty) continue;
      _database.setWorkLanguage(workId, language);
      return;
    }
  }

  Directory _safeWorkDirectory(String sourcePath) {
    final path = p.normalize(
      p.joinAll([root.path, ...p.posix.split(sourcePath)]),
    );
    if (!p.isWithin(root.path, path)) {
      throw StateError('Unsicherer Werkpfad im Bibliotheksindex: $sourcePath');
    }
    return Directory(path);
  }

  static File _manifestFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$manifestFileName');

  static File _databaseFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$databaseFileName');
}
