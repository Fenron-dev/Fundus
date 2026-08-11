import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'audio_technical_metadata.dart';

enum ScanEventKind { started, file, skipped, error, completed, cancelled }

final class ScannedFile {
  const ScannedFile({
    required this.absolutePath,
    required this.relativePath,
    required this.filename,
    required this.extension,
    required this.size,
    required this.modifiedAt,
    required this.mimeType,
    this.audioMetadata,
  });

  final String absolutePath;
  final String relativePath;
  final String filename;
  final String extension;
  final int size;
  final DateTime modifiedAt;
  final String? mimeType;
  final AudioTechnicalMetadata? audioMetadata;
}

final class ScanEvent {
  const ScanEvent({
    required this.kind,
    required this.visitedFiles,
    this.file,
    this.path,
    this.error,
  });

  final ScanEventKind kind;
  final int visitedFiles;
  final ScannedFile? file;
  final String? path;
  final Object? error;
}

final class ScanCancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

final class LibraryScanner {
  LibraryScanner({
    this.ignoredDirectoryNames = const {
      '.library',
      '_fundus',
      '.staging',
      '.git',
    },
    this.ignoredFileNames = const {'.DS_Store', 'Thumbs.db'},
  });

  final Set<String> ignoredDirectoryNames;
  final Set<String> ignoredFileNames;

  Stream<ScanEvent> scan(
    Directory root, {
    ScanCancellationToken? cancellationToken,
  }) async* {
    final rootPath = p.normalize(root.absolute.path);
    var visited = 0;
    yield ScanEvent(
      kind: ScanEventKind.started,
      visitedFiles: visited,
      path: rootPath,
    );

    if (!await root.exists()) {
      yield ScanEvent(
        kind: ScanEventKind.error,
        visitedFiles: visited,
        path: rootPath,
        error: FileSystemException('Bibliothek existiert nicht.', rootPath),
      );
      return;
    }

    final pending = <Directory>[root.absolute];
    while (pending.isNotEmpty) {
      if (cancellationToken?.isCancelled ?? false) {
        yield ScanEvent(kind: ScanEventKind.cancelled, visitedFiles: visited);
        return;
      }

      final directory = pending.removeLast();
      try {
        await for (final entity in directory.list(followLinks: false)) {
          if (cancellationToken?.isCancelled ?? false) {
            yield ScanEvent(
              kind: ScanEventKind.cancelled,
              visitedFiles: visited,
            );
            return;
          }
          final name = p.basename(entity.path);
          if (entity is Directory) {
            if (!ignoredDirectoryNames.contains(name)) pending.add(entity);
            continue;
          }
          if (entity is! File || ignoredFileNames.contains(name)) continue;

          visited++;
          try {
            final stat = await entity.stat();
            final extension = p
                .extension(name)
                .toLowerCase()
                .replaceFirst('.', '');
            final relative = p.relative(entity.absolute.path, from: rootPath);
            if (relative == '..' || relative.startsWith('../')) {
              yield ScanEvent(
                kind: ScanEventKind.skipped,
                visitedFiles: visited,
                path: entity.path,
              );
              continue;
            }
            yield ScanEvent(
              kind: ScanEventKind.file,
              visitedFiles: visited,
              file: ScannedFile(
                absolutePath: entity.absolute.path,
                relativePath: p.posix.joinAll(p.split(relative)),
                filename: name,
                extension: extension,
                size: stat.size,
                modifiedAt: stat.modified,
                mimeType: _mimeTypes[extension],
                audioMetadata: await AudioTechnicalMetadataProbe.inspect(
                  entity,
                  extension,
                  stat.size,
                ),
              ),
            );
          } catch (error) {
            yield ScanEvent(
              kind: ScanEventKind.error,
              visitedFiles: visited,
              path: entity.path,
              error: error,
            );
          }
        }
      } catch (error) {
        yield ScanEvent(
          kind: ScanEventKind.error,
          visitedFiles: visited,
          path: directory.path,
          error: error,
        );
      }
    }

    yield ScanEvent(kind: ScanEventKind.completed, visitedFiles: visited);
  }
}

const _mimeTypes = <String, String>{
  'm4b': 'audio/mp4',
  'm4a': 'audio/mp4',
  'mp3': 'audio/mpeg',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'opus': 'audio/opus',
  'wav': 'audio/wav',
  'mp4': 'video/mp4',
  'mkv': 'video/x-matroska',
  'webm': 'video/webm',
  'pdf': 'application/pdf',
  'epub': 'application/epub+zip',
  'zip': 'application/zip',
  'cbz': 'application/vnd.comicbook+zip',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'webp': 'image/webp',
};
