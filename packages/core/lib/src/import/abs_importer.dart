import 'package:path/path.dart' as p;

import 'abs_metadata.dart';
import '../scan/library_scanner.dart';

final class AbsBookIdentity {
  const AbsBookIdentity({
    required this.author,
    required this.title,
    this.series,
    this.sequence,
  });

  final String author;
  final String title;
  final String? series;
  final double? sequence;
}

final class AudiobookImportCandidate {
  const AudiobookImportCandidate({
    required this.identity,
    required this.directory,
    required this.audioFiles,
    required this.coverFiles,
    this.usesFallbackIdentity = false,
    this.absMetadata,
  });

  final AbsBookIdentity identity;
  final String directory;
  final List<ScannedFile> audioFiles;
  final List<ScannedFile> coverFiles;
  final bool usesFallbackIdentity;
  final AbsAudiobookMetadata? absMetadata;

  AudiobookImportCandidate copyWith({
    AbsBookIdentity? identity,
    AbsAudiobookMetadata? absMetadata,
  }) => AudiobookImportCandidate(
    identity: identity ?? this.identity,
    directory: directory,
    audioFiles: audioFiles,
    coverFiles: coverFiles,
    usesFallbackIdentity: usesFallbackIdentity,
    absMetadata: absMetadata ?? this.absMetadata,
  );
}

final class AbsImporter {
  static const audioExtensions = {
    'm4b',
    'm4a',
    'mp3',
    'flac',
    'ogg',
    'opus',
    'wav',
  };
  static const coverNames = {
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'folder.jpg',
  };

  AbsImporter({this.mediaRootNames = const ['Audiobooks', 'Hörbücher']});

  final List<String> mediaRootNames;

  AbsBookIdentity? parseBookDirectory(String relativeDirectory) {
    var parts = p.posix
        .split(p.posix.normalize(relativeDirectory))
        .where((part) => part != '.' && part.isNotEmpty)
        .toList(growable: false);
    final matchingRoots =
        mediaRootNames
            .map(
              (root) => p.posix
                  .split(p.posix.normalize(root.replaceAll('\\', '/')))
                  .where((part) => part != '.' && part.isNotEmpty)
                  .toList(growable: false),
            )
            .where((root) => root.isNotEmpty && _startsWith(parts, root))
            .toList()
          ..sort((left, right) => right.length.compareTo(left.length));
    if (matchingRoots.isNotEmpty) {
      parts = parts.sublist(matchingRoots.first.length);
    }
    if (parts.length < 2) return null;

    final author = parts.first;
    final bookFolder = parts.last;
    final parsedTitle = _parseSequence(bookFolder);
    if (parts.length == 2) {
      return AbsBookIdentity(
        author: author,
        title: parsedTitle.title,
        sequence: parsedTitle.sequence,
      );
    }
    return AbsBookIdentity(
      author: author,
      series: parts.sublist(1, parts.length - 1).join(' / '),
      title: parsedTitle.title,
      sequence: parsedTitle.sequence,
    );
  }

  static bool _startsWith(List<String> path, List<String> prefix) {
    if (prefix.length > path.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (path[index].toLowerCase() != prefix[index].toLowerCase()) {
        return false;
      }
    }
    return true;
  }

  List<AudiobookImportCandidate> group(Iterable<ScannedFile> files) {
    final byDirectory = <String, List<ScannedFile>>{};
    for (final file in files) {
      final directory = p.posix.dirname(file.relativePath);
      byDirectory.putIfAbsent(directory, () => []).add(file);
    }

    final candidates = <AudiobookImportCandidate>[];
    for (final entry in byDirectory.entries) {
      final audio =
          entry.value
              .where((file) => audioExtensions.contains(file.extension))
              .toList()
            ..sort(_compareTracks);
      if (audio.isEmpty) continue;
      final parsedIdentity = parseBookDirectory(entry.key);
      final identity = parsedIdentity ?? _fallbackIdentity(entry.key, audio);
      final covers = entry.value
          .where((file) => coverNames.contains(file.filename.toLowerCase()))
          .toList(growable: false);
      candidates.add(
        AudiobookImportCandidate(
          identity: identity,
          directory: entry.key,
          audioFiles: audio,
          coverFiles: covers,
          usesFallbackIdentity: parsedIdentity == null,
        ),
      );
    }
    candidates.sort((a, b) {
      final author = a.identity.author.compareTo(b.identity.author);
      if (author != 0) return author;
      final series = (a.identity.series ?? '').compareTo(
        b.identity.series ?? '',
      );
      if (series != 0) return series;
      return (a.identity.sequence ?? double.infinity).compareTo(
        b.identity.sequence ?? double.infinity,
      );
    });
    return candidates;
  }

  AbsBookIdentity _fallbackIdentity(String directory, List<ScannedFile> audio) {
    final normalized = p.posix.normalize(directory);
    final directoryName = normalized == '.'
        ? ''
        : p.posix.basename(normalized).trim();
    final fileTitle = p.basenameWithoutExtension(audio.first.filename).trim();
    return AbsBookIdentity(
      author: 'Unbekannt',
      title: directoryName.isNotEmpty ? directoryName : fileTitle,
    );
  }

  ({double? sequence, String title}) _parseSequence(String folder) {
    final match = RegExp(
      r'^(\d+(?:[.,]\d+)?)\s*[-–—]\s*(.+)$',
    ).firstMatch(folder);
    if (match == null) return (sequence: null, title: folder.trim());
    return (
      sequence: double.tryParse(match.group(1)!.replaceAll(',', '.')),
      title: match.group(2)!.trim(),
    );
  }

  static int _compareTracks(ScannedFile left, ScannedFile right) {
    final leftNumber = _leadingNumber(left.filename);
    final rightNumber = _leadingNumber(right.filename);
    if (leftNumber != null &&
        rightNumber != null &&
        leftNumber != rightNumber) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null && rightNumber == null) return -1;
    if (leftNumber == null && rightNumber != null) return 1;
    return left.filename.toLowerCase().compareTo(right.filename.toLowerCase());
  }

  static int? _leadingNumber(String filename) {
    final match = RegExp(r'^(\d+)').firstMatch(filename);
    return match == null ? null : int.parse(match.group(1)!);
  }
}
