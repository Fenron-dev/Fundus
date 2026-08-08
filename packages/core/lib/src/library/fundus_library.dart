import 'dart:io';

import '../database/fundus_database.dart';
import '../import/abs_importer.dart';
import '../model/fundus_id.dart';
import '../model/library_manifest.dart';
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

  List<LibraryWorkSummary> listWorks() => _database.listWorks();

  List<LibraryWorkSummary> searchWorks([
    LibraryWorkQuery query = const LibraryWorkQuery(),
  ]) => LibraryWorkSearch.apply(_database.listWorks(), query);

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
    _database.transaction(() {
      final ids = <String, String>{};
      for (final file in files) {
        ids[file.relativePath] = _database.upsertFile(file);
      }
      _database.markUnseenFilesMissing(ids.keys.toSet());
      for (final candidate in candidates) {
        _database.upsertAudiobookCandidate(candidate, ids);
      }
    });
    yield LibraryIndexEvent(
      phase: LibraryIndexPhase.completed,
      fileCount: files.length,
      workCount: candidates.length,
    );
  }

  void close() => _database.close();

  static File _manifestFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$manifestFileName');

  static File _databaseFile(Directory root) =>
      File('${root.path}/$metadataDirectoryName/$databaseFileName');
}
