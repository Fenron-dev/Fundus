import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../database/fundus_database.dart';
import '../import/abs_importer.dart';
import '../import/abs_metadata.dart';
import '../import/document_importer.dart';
import '../import/embedded_cover.dart';
import '../model/fundus_id.dart';
import '../model/library_configuration.dart';
import '../model/library_manifest.dart';
import '../model/library_playlist.dart';
import '../model/library_saved_view.dart';
import '../model/media_position.dart';
import '../model/playback_session.dart';
import '../playback/library_playback.dart';
import '../publication/epub_package.dart';
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
    this.rootCounts = const {},
    this.extensionCounts = const {},
  });

  final LibraryIndexPhase phase;
  final int fileCount;
  final int workCount;
  final String? currentPath;
  final Map<String, int> rootCounts;
  final Map<String, int> extensionCounts;
}

final class _PortableWorkIdentity {
  const _PortableWorkIdentity({
    this.workId,
    required this.writable,
    this.identity,
  });

  final String? workId;
  final bool writable;
  final AbsBookIdentity? identity;
}

final class FundusLibrary {
  FundusLibrary._({
    required this.root,
    required this.manifest,
    required this.configuration,
    required this.openMode,
    required FundusDatabase database,
  }) : _database = database;

  static const metadataDirectoryName = '.library';
  static const manifestFileName = 'version.json';
  static const databaseFileName = 'index.db';
  static const configurationFileName = 'config.yaml';

  final Directory root;
  final LibraryManifest manifest;
  final LibraryConfiguration configuration;
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
    final configuration = LibraryConfiguration();
    await configuration.write(_configurationFile(root));
    return FundusLibrary._(
      root: root.absolute,
      manifest: manifest,
      configuration: configuration,
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
    final configuration = await LibraryConfiguration.readOrDefault(
      _configurationFile(root),
    );
    final compatibility = manifest.compatibility();
    if (compatibility.mode == LibraryOpenMode.incompatible) {
      throw StateError(compatibility.message);
    }
    return FundusLibrary._(
      root: root.absolute,
      manifest: manifest,
      configuration: configuration,
      openMode: compatibility.mode,
      database: FundusDatabase.openFile(
        _databaseFile(root),
        readOnly: compatibility.mode == LibraryOpenMode.readOnly,
      ),
    );
  }

  List<LibraryWorkSummary> listWorks({bool includeMissing = false}) => _database
      .listWorks(includeMissing: includeMissing)
      .map(_withAbsoluteCoverPath)
      .toList(growable: false);

  List<LibraryWorkSummary> searchWorks([
    LibraryWorkQuery query = const LibraryWorkQuery(),
  ]) => LibraryWorkSearch.apply(listWorks(), query);

  Future<List<LibrarySavedView>> loadSavedViews() async {
    final file = File(
      p.join(root.path, metadataDirectoryName, 'saved_views.json'),
    );
    if (!await file.exists()) return const [];
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! List) return const [];
      final views = value
          .map(LibrarySavedView.fromJson)
          .whereType<LibrarySavedView>()
          .toList();
      views.sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
      return views;
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  Future<List<LibrarySavedView>> saveView(
    String name,
    LibraryWorkQuery query,
  ) async {
    _ensureWritable();
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw ArgumentError('Der Name darf nicht leer sein.');
    }
    final views = await loadSavedViews();
    final existing = views
        .where((view) => view.name.toLowerCase() == normalized.toLowerCase())
        .firstOrNull;
    final saved = LibrarySavedView(
      id: existing?.id ?? FundusId.generate(),
      name: normalized,
      query: query,
      updatedAt: DateTime.now().toUtc(),
    );
    final updated = [...views.where((view) => view.id != saved.id), saved]
      ..sort(
        (left, right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
    await _writeSavedViews(updated);
    return updated;
  }

  Future<List<LibrarySavedView>> deleteSavedView(String id) async {
    _ensureWritable();
    final updated = (await loadSavedViews())
        .where((view) => view.id != id)
        .toList(growable: false);
    await _writeSavedViews(updated);
    return updated;
  }

  Future<void> _writeSavedViews(List<LibrarySavedView> views) async {
    final file = File(
      p.join(root.path, metadataDirectoryName, 'saved_views.json'),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(views.map((view) => view.toJson()).toList())}\n',
      flush: true,
    );
  }

  void deleteMissingWork(String workId) {
    _ensureWritable();
    _database.deleteMissingWork(workId);
  }

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
            audioMetadata: track.audioMetadata,
          );
        })
        .toList(growable: false);
  }

  Future<List<LibraryPlaybackChapter>> playbackChapters(String workId) async {
    final tracks = playbackTracks(workId);
    if (tracks.isEmpty) return const [];
    if (tracks.length > 1) {
      return [
        for (var index = 0; index < tracks.length; index++)
          LibraryPlaybackChapter(
            title: p.basenameWithoutExtension(tracks[index].title),
            fileId: tracks[index].fileId,
            trackIndex: index,
            position: Duration.zero,
            duration: tracks[index].duration,
          ),
      ];
    }

    final track = tracks.single;
    final embedded = await const EmbeddedCoverExtractor().extractChapters(
      File(track.absolutePath),
    );
    if (embedded.isEmpty) {
      return [
        LibraryPlaybackChapter(
          title: p.basenameWithoutExtension(track.title),
          fileId: track.fileId,
          trackIndex: 0,
          position: Duration.zero,
          duration: track.duration,
        ),
      ];
    }
    return [
      for (var index = 0; index < embedded.length; index++)
        LibraryPlaybackChapter(
          title: embedded[index].title,
          fileId: track.fileId,
          trackIndex: 0,
          position: embedded[index].position,
          duration: index + 1 < embedded.length
              ? embedded[index + 1].position - embedded[index].position
              : track.duration == null
              ? null
              : track.duration! - embedded[index].position,
        ),
    ];
  }

  String? workDirectoryPath(String workId) {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return null;
    return _portableWorkDirectory(sourcePath).path;
  }

  Future<Map<String, Object?>?> loadPortableReaderProfile({
    required String workId,
    required String deviceKey,
    required String readerKind,
  }) async {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return null;
    final file = File(
      p.join(_workSidecarDirectory(sourcePath).path, 'reader-settings.yaml'),
    );
    if (!await file.exists()) return null;
    try {
      final value = loadYaml(await file.readAsString());
      if (value is! Map) return null;
      final devices = value['devices'];
      if (devices is! Map) return null;
      final device = devices[deviceKey];
      if (device is! Map) return null;
      final profile = device[readerKind];
      return profile is Map
          ? Map<String, Object?>.from(profile.cast<Object?, Object?>())
          : null;
    } on FileSystemException {
      return null;
    } on YamlException {
      return null;
    }
  }

  Future<void> savePortableReaderProfile({
    required String workId,
    required String deviceKey,
    required String readerKind,
    required Map<String, Object?> profile,
  }) async {
    _ensureWritable();
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return;
    final directory = _workSidecarDirectory(sourcePath);
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, 'reader-settings.yaml'));
    var values = <String, Object?>{'format_version': 1};
    if (await file.exists()) {
      try {
        final decoded = loadYaml(await file.readAsString());
        if (decoded is Map) {
          values = Map<String, Object?>.from(decoded.cast<Object?, Object?>());
        }
      } on FileSystemException {
        // A new portable settings file can replace an unreadable old one.
      } on YamlException {
        // A malformed optional profile must not block the reader.
      }
    }
    final devices = values['devices'] is Map
        ? Map<String, Object?>.from(values['devices'] as Map)
        : <String, Object?>{};
    final device = devices[deviceKey] is Map
        ? Map<String, Object?>.from(devices[deviceKey] as Map)
        : <String, Object?>{};
    device[readerKind] = profile;
    devices[deviceKey] = device;
    values['devices'] = devices;
    final partial = File('${file.path}.part');
    await partial.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(values)}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
  }

  LibraryPlaybackProgress? loadProgress(String workId) =>
      _database.loadProgress(workId);

  List<LibraryPlaybackRevision> listProgressRevisions(String workId) =>
      _database.listProgressRevisions(workId);

  LibraryPlaybackProgress restoreProgressRevision({
    required String workId,
    required int revision,
    String deviceId = 'desktop-local',
    String? operationId,
  }) {
    _ensureWritable();
    return _database.restoreProgressRevision(
      workId: workId,
      revision: revision,
      deviceId: deviceId,
      operationId: operationId ?? FundusId.generate(),
    );
  }

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

  LibraryPlaybackProgress saveMediaProgress({
    required String workId,
    required String fileId,
    required MediaPosition position,
    bool finished = false,
    String deviceId = 'desktop-local',
    String? operationId,
  }) => _database.saveMediaProgress(
    workId: workId,
    fileId: fileId,
    position: position,
    finished: finished,
    deviceId: deviceId,
    operationId: operationId ?? FundusId.generate(),
  );

  Future<String> cacheGeneratedCover({
    required String workId,
    required Uint8List bytes,
    String extension = 'png',
  }) async {
    _ensureWritable();
    if (bytes.isEmpty) throw ArgumentError.value(bytes, 'bytes');
    final normalizedExtension = extension.toLowerCase() == 'jpg'
        ? 'jpg'
        : 'png';
    final directory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    await directory.create(recursive: true);
    final filename = '$workId.document.$normalizedExtension';
    final target = File(p.join(directory.path, filename));
    await target.writeAsBytes(bytes, flush: true);
    _database.setGeneratedCoverPath(
      workId,
      p.posix.join(metadataDirectoryName, 'covers', filename),
    );
    return target.path;
  }

  PlaybackSession savePlaybackSession(
    PlaybackSession session, {
    String userId = 'default',
    String deviceId = 'desktop-local',
    int? expectedRevision,
  }) {
    _ensureWritable();
    return _database.savePlaybackSession(
      session,
      userId: userId,
      deviceId: deviceId,
      expectedRevision: expectedRevision,
    );
  }

  PlaybackSession? loadPlaybackSession(String sessionId) =>
      _database.loadPlaybackSession(sessionId);

  PlaybackSession? latestPlaybackSession({String userId = 'default'}) =>
      _database.latestPlaybackSession(userId: userId);

  List<LibraryPlaylist> listPlaylists() => _database.listPlaylists();

  LibraryPlaylist? loadPlaylist(String playlistId) =>
      _database.loadPlaylist(playlistId);

  LibraryPlaylist savePlaylist({
    String? playlistId,
    required String name,
    required List<String> workIds,
    String? mediaType,
  }) {
    _ensureWritable();
    return _database.savePlaylist(
      playlistId: playlistId,
      name: name,
      workIds: workIds,
      mediaType: mediaType,
    );
  }

  void deletePlaylist(String playlistId) {
    _ensureWritable();
    _database.deletePlaylist(playlistId);
  }

  WorkAnnotations loadAnnotations(String workId) =>
      _database.loadAnnotations(workId);

  List<String> listTags() => _database.listTags();

  Future<LibraryWorkSummary> updateWorkMetadata({
    required String workId,
    required String title,
    required List<String> authors,
    String? subtitle,
    String? series,
    double? seriesSequence,
    List<String> narrators = const [],
    String? language,
    String? description,
    String? publisher,
    int? publishedYear,
    String? contentSensitivity,
  }) async {
    _ensureWritable();
    _database.updateWorkMetadata(
      workId: workId,
      title: title,
      authors: authors,
      subtitle: subtitle,
      series: series,
      seriesSequence: seriesSequence,
      narrators: narrators,
      language: language,
      description: description,
      publisher: publisher,
      publishedYear: publishedYear,
      contentSensitivity: contentSensitivity,
    );
    await _writeMetadataSidecar(workId);
    return listWorks(
      includeMissing: true,
    ).firstWhere((work) => work.id == workId);
  }

  Future<WorkAnnotations> replaceWorkTags(
    String workId,
    Iterable<String> tags,
  ) async {
    _ensureWritable();
    _database.replaceWorkTags(workId, tags);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> saveWorkNote(String workId, String markdown) async {
    _ensureWritable();
    final normalized = markdown.trim();
    if (normalized.isEmpty) return loadAnnotations(workId);
    _database.saveWorkNote(workId, normalized);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
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
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> addMediaBookmark({
    required String workId,
    required String fileId,
    required MediaPosition position,
    String? label,
    String? note,
  }) async {
    _ensureWritable();
    _database.addMediaBookmark(
      workId: workId,
      fileId: fileId,
      mediaPosition: position,
      label: label,
      note: note,
    );
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> deleteBookmark(
    String workId,
    String bookmarkId,
  ) async {
    _ensureWritable();
    _database.deleteBookmark(bookmarkId);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> addTextHighlight({
    required String workId,
    required String fileId,
    required MediaPosition position,
    required String quote,
    String color = '#FFF176',
    String? note,
  }) async {
    _ensureWritable();
    if (quote.trim().isEmpty) return loadAnnotations(workId);
    _database.addTextHighlight(
      workId: workId,
      fileId: fileId,
      mediaPosition: position,
      quote: quote,
      color: color,
      note: note,
    );
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
    return loadAnnotations(workId);
  }

  Future<WorkAnnotations> deleteHighlight(
    String workId,
    String highlightId,
  ) async {
    _ensureWritable();
    _database.deleteHighlight(highlightId);
    if (_usesPortableSidecars(workId)) {
      await _writeAnnotationSidecars(workId);
    }
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

    final groupedCandidates =
        (importer ??
                AbsImporter(
                  mediaRootNames: configuration.rootsFor('audiobook'),
                ))
            .group(files);
    final rootCounts = _countScannedFiles(
      files,
      (file) => p.posix.split(file.relativePath).firstOrNull ?? '(root)',
    );
    final extensionCounts = _countScannedFiles(
      files,
      (file) => file.extension.isEmpty ? '(ohne Endung)' : file.extension,
    );
    final groupedDocumentCandidates = DocumentImporter(
      mediaRoots: configuration.mediaRoots,
    ).group(files);
    final documentCandidates = <DocumentImportCandidate>[];
    for (final candidate in groupedDocumentCandidates) {
      documentCandidates.add(await _withEpubMetadata(candidate));
    }
    final candidates = <AudiobookImportCandidate>[];
    final portableIdentities = <String, _PortableWorkIdentity>{};
    for (final grouped in groupedCandidates) {
      final portable = await _readPortableIdentity(grouped);
      portableIdentities[grouped.directory] = portable;
      final withAbsMetadata = await _withAbsMetadata(grouped);
      if (portable.identity case final identity?) {
        candidates.add(
          withAbsMetadata.copyWith(
            identity: identity,
            metadataSource: WorkMetadataSource.sidecar,
          ),
        );
      } else if (withAbsMetadata.absMetadata == null &&
          grouped.usesFallbackIdentity) {
        candidates.add(await _withEmbeddedIdentity(withAbsMetadata));
      } else {
        candidates.add(withAbsMetadata);
      }
    }
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.importing,
      fileCount: files.length,
      workCount: candidates.length + documentCandidates.length,
    );
    final indexedDocuments =
        <({DocumentImportCandidate candidate, String workId})>[];
    final indexedCandidates = _database.transaction(() {
      final ids = <String, String>{};
      final indexed = <({AudiobookImportCandidate candidate, String workId})>[];
      for (final file in files) {
        ids[file.relativePath] = _database.upsertFile(file);
      }
      _database.markUnseenFilesMissing(ids.keys.toSet());
      for (final candidate in candidates) {
        final portableId = portableIdentities[candidate.directory]?.workId;
        indexed.add((
          candidate: candidate,
          workId: _database.upsertAudiobookCandidate(
            candidate,
            ids,
            preferredWorkId:
                portableId ?? _database.findMovedAudiobookWorkId(candidate),
          ),
        ));
      }
      for (final candidate in documentCandidates) {
        indexedDocuments.add((
          candidate: candidate,
          workId: _database.upsertDocumentCandidate(candidate, ids),
        ));
      }
      _database.markWorksWithoutAvailableContentMissing();
      return indexed;
    });
    for (final indexed in indexedDocuments) {
      await _cachePublicationCover(indexed.candidate, indexed.workId);
      await _importAnnotationSidecars(
        indexed.candidate.directory,
        indexed.workId,
      );
    }
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
        await _importAnnotationSidecars(
          indexed.candidate.directory,
          indexed.workId,
        );
      } on FileSystemException {
        // A broken sidecar must not make the complete library unavailable.
      } on YamlException {
        // The user can repair malformed portable metadata and scan again.
      }
      await _importAbsTags(indexed.candidate, indexed.workId);
      await _cacheEmbeddedCover(indexed.candidate, indexed.workId);
      if (portableIdentities[indexed.candidate.directory]?.writable ?? false) {
        await _writeMetadataSidecar(indexed.workId);
      }
    }
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.completed,
      fileCount: files.length,
      workCount: candidates.length + documentCandidates.length,
      rootCounts: rootCounts,
      extensionCounts: extensionCounts,
    );
  }

  static Map<String, int> _countScannedFiles(
    Iterable<ScannedFile> files,
    String Function(ScannedFile file) keyFor,
  ) {
    final counts = <String, int>{};
    for (final file in files) {
      final key = keyFor(file);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final entries = counts.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    return {for (final entry in entries) entry.key: entry.value};
  }

  Future<DocumentImportCandidate> _withEpubMetadata(
    DocumentImportCandidate candidate,
  ) async {
    if (candidate.kind != 'ebook' && candidate.kind != 'webnovel') {
      return candidate;
    }
    final source = candidate.files
        .where((file) => file.extension.toLowerCase() == 'epub')
        .firstOrNull;
    if (source == null) return candidate;
    try {
      final publication = await const EpubPackageAdapter().openFile(
        source.absolutePath,
      );
      return candidate.copyWith(
        title: publication.title,
        metadata: {
          if (publication.authors.isNotEmpty)
            'author': publication.authors.join(', '),
          if (publication.authors.isNotEmpty) 'authors': publication.authors,
          if (publication.languages.isNotEmpty)
            'language': publication.languages.first,
          'description': ?publication.description,
          if (publication.subjects.isNotEmpty) 'genres': publication.subjects,
          if (publication.publishers.isNotEmpty)
            'publisher': publication.publishers.join(', '),
        },
        embeddedCoverBytes: candidate.coverFile == null
            ? publication.coverBytes
            : null,
        embeddedCoverMimeType: candidate.coverFile == null
            ? publication.coverMimeType
            : null,
      );
    } on FileSystemException {
      return candidate;
    } on EpubPackageException {
      return candidate;
    }
  }

  Future<void> _cachePublicationCover(
    DocumentImportCandidate candidate,
    String workId,
  ) async {
    if (candidate.coverFile != null) return;
    final bytes = candidate.embeddedCoverBytes;
    if (bytes == null || bytes.isEmpty) return;
    final extension = switch (candidate.embeddedCoverMimeType?.toLowerCase()) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/jpeg' || 'image/jpg' => 'jpg',
      _ => null,
    };
    if (extension == null) return;
    final coverDirectory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    try {
      await coverDirectory.create(recursive: true);
      final filename = '$workId.$extension';
      await File(
        p.join(coverDirectory.path, filename),
      ).writeAsBytes(bytes, flush: true);
      _database.setGeneratedCoverPath(
        workId,
        p.posix.join(metadataDirectoryName, 'covers', filename),
      );
    } on FileSystemException {
      // Metadata remains usable when an embedded cover cannot be cached.
    }
  }

  Future<AudiobookImportCandidate> _withAbsMetadata(
    AudiobookImportCandidate candidate,
  ) async {
    try {
      final metadata = await const AbsMetadataReader().read(
        File(
          p.join(_safeWorkDirectory(candidate.directory).path, 'metadata.json'),
        ),
      );
      if (metadata == null) return candidate;
      return candidate.copyWith(
        absMetadata: metadata,
        metadataSource: WorkMetadataSource.abs,
        identity: AbsBookIdentity(
          author: metadata.author ?? candidate.identity.author,
          title: metadata.title ?? candidate.identity.title,
          series: metadata.series ?? candidate.identity.series,
          sequence: metadata.sequence ?? candidate.identity.sequence,
        ),
      );
    } on FileSystemException {
      return candidate;
    } on FormatException {
      return candidate;
    }
  }

  Future<void> _importAbsTags(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final metadata = candidate.absMetadata;
    if (metadata == null) return;
    final existing = loadAnnotations(workId);
    if (existing.tags.isNotEmpty) return;
    final tags = {...metadata.tags, ...metadata.genres};
    if (tags.isEmpty) return;
    _database.replaceWorkTags(workId, tags);
  }

  Future<AudiobookImportCandidate> _withEmbeddedIdentity(
    AudiobookImportCandidate candidate,
  ) async {
    if (candidate.audioFiles.isEmpty) return candidate;
    try {
      final metadata = await const EmbeddedCoverExtractor().extractMetadata(
        File(candidate.audioFiles.first.absolutePath),
      );
      if (metadata.isEmpty) return candidate;
      final title = candidate.audioFiles.length > 1
          ? metadata.album ?? candidate.identity.title
          : metadata.title ?? metadata.album ?? candidate.identity.title;
      return candidate.copyWith(
        metadataSource: WorkMetadataSource.embedded,
        identity: AbsBookIdentity(
          author:
              metadata.albumArtist ??
              metadata.author ??
              candidate.identity.author,
          title: title,
          series: metadata.series ?? candidate.identity.series,
          sequence: metadata.part ?? candidate.identity.sequence,
        ),
      );
    } on FileSystemException {
      return candidate;
    } on FormatException {
      return candidate;
    }
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
    final safeCoverPath = p.isWithin(root.path, absolutePath)
        ? absolutePath
        : null;
    return LibraryWorkSummary(
      id: work.id,
      kind: work.kind,
      title: work.title,
      author: work.author,
      authors: work.authors,
      fileCount: work.fileCount,
      addedAt: work.addedAt,
      series: work.series,
      seriesSequence: work.seriesSequence,
      coverPath: safeCoverPath,
      language: work.language,
      subtitle: work.subtitle,
      description: work.description,
      narrators: work.narrators,
      genres: work.genres,
      publisher: work.publisher,
      publishedYear: work.publishedYear,
      isbn: work.isbn,
      asin: work.asin,
      explicit: work.explicit,
      contentSensitivity: work.contentSensitivity,
      abridged: work.abridged,
      progressPosition: work.progressPosition,
      progressDuration: work.progressDuration,
      mediaProgress: work.mediaProgress,
      progressTrackIndex: work.progressTrackIndex,
      progressFinished: work.progressFinished,
      status: work.status,
      metadataOrigins: work.metadataOrigins,
      tags: work.tags,
      lastListenedAt: work.lastListenedAt,
      offline: work.offline,
    );
  }

  Future<void> _cacheEmbeddedCover(
    AudiobookImportCandidate candidate,
    String workId,
  ) async {
    final coverDirectory = Directory(
      p.join(root.path, metadataDirectoryName, 'covers'),
    );
    if (candidate.coverFiles.isNotEmpty) {
      final source = candidate.coverFiles.first;
      final extension = source.extension == 'png' ? 'png' : 'jpg';
      try {
        await coverDirectory.create(recursive: true);
        final filename = '$workId.$extension';
        await File(
          source.absolutePath,
        ).copy(p.join(coverDirectory.path, filename));
        _database.setGeneratedCoverPath(
          workId,
          p.posix.join(metadataDirectoryName, 'covers', filename),
        );
        return;
      } on FileSystemException {
        // An unreadable external cover can still fall back to embedded artwork.
      }
    }
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
    final sidecarDirectory = _workSidecarDirectory(sourcePath);
    await sidecarDirectory.create(recursive: true);
    final annotations = loadAnnotations(workId);
    await File(
      p.join(sidecarDirectory.path, 'notes.md'),
    ).writeAsString(_serializeNotes(annotations.notes), flush: true);
    await _writeMetadataSidecar(workId);
    final tracksById = {
      for (final track in playbackTracks(workId))
        track.fileId: track.relativePath,
    };
    await File(p.join(sidecarDirectory.path, 'bookmarks.yaml')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'format_version': 2,
        'bookmarks': [
          for (final bookmark in annotations.bookmarks)
            {
              'id': bookmark.id,
              'file_path': tracksById[bookmark.fileId],
              'position': bookmark.mediaPosition.toJson(),
              if (bookmark.mediaPosition.kind == MediaPositionKind.time)
                'position_ms': bookmark.position.inMilliseconds,
              'label': bookmark.label,
              'note': bookmark.note,
              'created_at': bookmark.createdAt.toUtc().toIso8601String(),
            },
        ],
        'highlights': [
          for (final highlight in annotations.highlights)
            {
              'id': highlight.id,
              'file_path': tracksById[highlight.fileId],
              'position': highlight.mediaPosition.toJson(),
              'quote': highlight.quote,
              'color': highlight.color,
              'note': highlight.note,
              'created_at': highlight.createdAt.toUtc().toIso8601String(),
            },
        ],
      }),
      flush: true,
    );
  }

  Future<_PortableWorkIdentity> _readPortableIdentity(
    AudiobookImportCandidate candidate,
  ) async {
    final file = File(
      p.joinAll([
        root.path,
        ...p.posix.split(candidate.directory),
        '_fundus',
        'meta.yaml',
      ]),
    );
    if (!await file.exists()) {
      return const _PortableWorkIdentity(writable: true);
    }
    try {
      final value = loadYaml(await file.readAsString());
      if (value is! Map) {
        return const _PortableWorkIdentity(writable: false);
      }
      final baseKind = value['base_kind'];
      if (baseKind != null && baseKind != 'audiobook') {
        return const _PortableWorkIdentity(writable: false);
      }
      final workId = value['work_id'];
      if (workId != null &&
          (workId is! String || !_uuidPattern.hasMatch(workId))) {
        return const _PortableWorkIdentity(writable: false);
      }
      final title = value['title'];
      final author = value['author'];
      final series = value['series'];
      final sequence = value['series_sequence'];
      final identity =
          title is String &&
              title.trim().isNotEmpty &&
              author is String &&
              author.trim().isNotEmpty
          ? AbsBookIdentity(
              title: title.trim(),
              author: author.trim(),
              series: series is String && series.trim().isNotEmpty
                  ? series.trim()
                  : null,
              sequence: sequence is num ? sequence.toDouble() : null,
            )
          : null;
      return _PortableWorkIdentity(
        workId: workId as String?,
        writable: true,
        identity: identity,
      );
    } on FileSystemException {
      return const _PortableWorkIdentity(writable: false);
    } on YamlException {
      return const _PortableWorkIdentity(writable: false);
    }
  }

  Future<void> _writeMetadataSidecar(String workId) async {
    final sourcePath = _database.workSourcePath(workId);
    if (sourcePath == null) return;
    final directory = _workSidecarDirectory(sourcePath);
    await directory.create(recursive: true);
    final annotations = loadAnnotations(workId);
    final work = listWorks().where((work) => work.id == workId).firstOrNull;
    if (work == null) return;
    await File(p.join(directory.path, 'meta.yaml')).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({
        'format_version': 3,
        'work_id': workId,
        'base_kind': work.kind,
        'custom_type': null,
        'title': work.title,
        'author': work.author,
        'authors': work.authors,
        'subtitle': work.subtitle,
        'series': work.series,
        'series_sequence': work.seriesSequence,
        'narrators': work.narrators,
        'language': work.language,
        'description': work.description,
        'publisher': work.publisher,
        'published_year': work.publishedYear,
        'content_sensitivity': work.contentSensitivity,
        'field_sources': {
          for (final entry in work.metadataOrigins.entries) entry.key: {'source': entry.value.source.name, 'updated_at': entry.value.updatedAt.toUtc().toIso8601String()},
        },
        'tags': annotations.tags,
      })}\n',
      flush: true,
    );
  }

  Future<void> _importAnnotationSidecars(
    String sourcePath,
    String workId,
  ) async {
    final sidecarDirectory = _workSidecarDirectory(sourcePath);
    if (!await sidecarDirectory.exists()) return;
    var annotations = loadAnnotations(workId);
    final noteFile = File(p.join(sidecarDirectory.path, 'notes.md'));
    if (annotations.notes.isEmpty && await noteFile.exists()) {
      final source = await noteFile.readAsString();
      final notes = _parseNotes(source);
      if (notes.isEmpty && source.trim().isNotEmpty) {
        _database.saveWorkNote(
          workId,
          source.trim(),
          updatedAt: await noteFile.lastModified(),
        );
      } else {
        for (final note in notes) {
          _database.saveWorkNote(
            workId,
            note.markdown,
            updatedAt: note.createdAt,
          );
        }
      }
    }
    final metaFile = File(p.join(sidecarDirectory.path, 'meta.yaml'));
    if (await metaFile.exists()) {
      final value = loadYaml(await metaFile.readAsString());
      if (value is Map) {
        if (annotations.tags.isEmpty && value['tags'] is List) {
          _database.replaceWorkTags(
            workId,
            (value['tags'] as List).whereType<String>(),
          );
        }
        final title = value['title'];
        final author = value['author'];
        final authors = value['authors'];
        if (title is String &&
            title.trim().isNotEmpty &&
            (author is String || authors is List)) {
          final fieldOrigins = _readFieldOrigins(value['field_sources']);
          _database.updateWorkMetadata(
            workId: workId,
            title: title,
            authors: authors is List && authors.whereType<String>().isNotEmpty
                ? authors.whereType<String>().toList(growable: false)
                : [author as String],
            subtitle: value['subtitle'] as String?,
            series: value['series'] as String?,
            seriesSequence: (value['series_sequence'] as num?)?.toDouble(),
            narrators: (value['narrators'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            language: value['language'] as String?,
            description: value['description'] as String?,
            publisher: value['publisher'] as String?,
            publishedYear: (value['published_year'] as num?)?.round(),
            contentSensitivity: _readContentSensitivity(
              value['content_sensitivity'],
            ),
            source: WorkMetadataSource.sidecar,
            updatedAt: await metaFile.lastModified(),
            fieldOrigins: fieldOrigins,
          );
        }
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
          if (fileId == null) continue;
          final id = item['id'];
          final label = item['label'];
          final note = item['note'];
          final createdAt = item['created_at'];
          final rawPosition = item['position'];
          if (rawPosition is Map) {
            try {
              final restored = MediaPosition.fromJson(
                rawPosition.cast<String, Object?>(),
              );
              _database.addMediaBookmark(
                id: id is String ? id : null,
                workId: workId,
                fileId: fileId,
                mediaPosition: restored.withFileId(fileId),
                label: label is String ? label : null,
                note: note is String ? note : null,
                createdAt: createdAt is String
                    ? DateTime.tryParse(createdAt)
                    : null,
              );
              continue;
            } catch (_) {
              // Fall back to the version-one time position below.
            }
          }
          final positionMs = item['position_ms'];
          if (positionMs is num) {
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
    annotations = loadAnnotations(workId);
    if (annotations.highlights.isEmpty && await bookmarksFile.exists()) {
      final value = loadYaml(await bookmarksFile.readAsString());
      final highlights = value is Map ? value['highlights'] : null;
      if (highlights is List) {
        final tracksByPath = {
          for (final track in playbackTracks(workId))
            track.relativePath: track.fileId,
        };
        for (final item in highlights.whereType<Map>()) {
          final fileId = tracksByPath[item['file_path']];
          final rawPosition = item['position'];
          final quote = item['quote'];
          if (fileId == null || rawPosition is! Map || quote is! String) {
            continue;
          }
          try {
            _database.addTextHighlight(
              id: item['id'] as String?,
              workId: workId,
              fileId: fileId,
              mediaPosition: MediaPosition.fromJson(
                rawPosition.cast<String, Object?>(),
              ).withFileId(fileId),
              quote: quote,
              color: item['color'] as String? ?? '#FFF176',
              note: item['note'] as String?,
              createdAt: item['created_at'] is String
                  ? DateTime.tryParse(item['created_at'] as String)
                  : null,
            );
          } on FormatException {
            // Ignore one malformed portable highlight.
          }
        }
      }
    }
  }

  static String? _readContentSensitivity(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim();
    return FundusDatabase.supportedContentSensitivities.contains(normalized)
        ? normalized
        : null;
  }

  static Map<String, WorkMetadataOrigin> _readFieldOrigins(Object? value) {
    if (value is! Map) return const {};
    final result = <String, WorkMetadataOrigin>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! Map) continue;
      final raw = entry.value as Map;
      final sourceName = raw['source']?.toString();
      WorkMetadataSource? source;
      for (final candidate in WorkMetadataSource.values) {
        if (candidate.name == sourceName) source = candidate;
      }
      final updatedAt = DateTime.tryParse(raw['updated_at']?.toString() ?? '');
      if (source != null && updatedAt != null) {
        result[entry.key as String] = WorkMetadataOrigin(
          source: source,
          updatedAt: updatedAt.toUtc(),
        );
      }
    }
    return result;
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
        _database.setWorkLanguage(
          workId,
          value['language'] as String,
          source: WorkMetadataSource.sidecar,
          updatedAt: await fundusMeta.lastModified(),
        );
        return;
      }
    }

    final absLanguage = candidate.absMetadata?.language;
    if (absLanguage != null && absLanguage.trim().isNotEmpty) {
      _database.setWorkLanguage(
        workId,
        absLanguage,
        source: WorkMetadataSource.abs,
      );
      return;
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
          _database.setWorkLanguage(
            workId,
            language,
            source: WorkMetadataSource.sidecar,
            updatedAt: await sourceFile.lastModified(),
          );
          return;
        }
      }
    }

    const extractor = EmbeddedCoverExtractor();
    for (final audio in candidate.audioFiles) {
      final file = File(audio.absolutePath);
      final metadata = await extractor.extractMetadata(file);
      final language =
          metadata.language ?? await extractor.extractLanguage(file);
      if (language == null || language.trim().isEmpty) continue;
      _database.setWorkLanguage(
        workId,
        language,
        source: WorkMetadataSource.embedded,
      );
      return;
    }
  }

  static String _serializeNotes(List<LibraryNote> notes) {
    if (notes.isEmpty) return '';
    return '${notes.map((note) {
      final local = note.createdAt.toLocal();
      final date = '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      return '<!-- fundus-note: ${note.createdAt.toUtc().toIso8601String()} -->\n'
          '## $date\n\n${note.markdown.trim()}';
    }).join('\n\n')}\n';
  }

  static List<({String markdown, DateTime createdAt})> _parseNotes(
    String source,
  ) {
    final marker = RegExp(r'<!-- fundus-note: ([^>]+) -->\s*\n## [^\n]*\n\s*');
    final matches = marker.allMatches(source).toList(growable: false);
    if (matches.isEmpty) return const [];
    final notes = <({String markdown, DateTime createdAt})>[];
    for (var index = 0; index < matches.length; index++) {
      final match = matches[index];
      final createdAt = DateTime.tryParse(match.group(1)!.trim());
      if (createdAt == null) continue;
      final end = index + 1 < matches.length
          ? matches[index + 1].start
          : source.length;
      final markdown = source.substring(match.end, end).trim();
      if (markdown.isEmpty) continue;
      notes.add((markdown: markdown, createdAt: createdAt));
    }
    return notes;
  }

  Directory _safeWorkDirectory(String sourcePath) {
    final path = p.normalize(
      p.joinAll([root.path, ...p.posix.split(sourcePath)]),
    );
    final normalizedRoot = p.normalize(root.path);
    if (path != normalizedRoot && !p.isWithin(normalizedRoot, path)) {
      throw StateError('Unsicherer Werkpfad im Bibliotheksindex: $sourcePath');
    }
    return Directory(path);
  }

  Directory _portableWorkDirectory(String sourcePath) {
    final target = _safeWorkDirectory(sourcePath);
    return FileSystemEntity.isFileSync(target.path) ? target.parent : target;
  }

  Directory _workSidecarDirectory(String sourcePath) {
    final target = _safeWorkDirectory(sourcePath);
    if (!FileSystemEntity.isFileSync(target.path)) {
      return Directory(p.join(target.path, '_fundus'));
    }
    return Directory(
      p.join(target.parent.path, '_fundus', 'files', p.basename(target.path)),
    );
  }

  bool _usesPortableSidecars(String workId) =>
      listWorks(includeMissing: true).any((work) => work.id == workId);

  static File _manifestFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$manifestFileName');

  static File _databaseFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$databaseFileName');

  static File _configurationFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$configurationFileName');

  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
}
