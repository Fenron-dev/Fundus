import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../scan/library_scanner.dart';

final class DocumentImportCandidate {
  const DocumentImportCandidate({
    required this.kind,
    required this.directory,
    required this.title,
    required this.files,
    this.coverFile,
    this.metadata = const {},
    this.embeddedCoverBytes,
    this.embeddedCoverMimeType,
  });

  final String kind;
  final String directory;
  final String title;
  final List<ScannedFile> files;
  final ScannedFile? coverFile;
  final Map<String, Object?> metadata;
  final Uint8List? embeddedCoverBytes;
  final String? embeddedCoverMimeType;

  DocumentImportCandidate copyWith({
    String? title,
    Map<String, Object?>? metadata,
    Uint8List? embeddedCoverBytes,
    String? embeddedCoverMimeType,
  }) => DocumentImportCandidate(
    kind: kind,
    directory: directory,
    title: title ?? this.title,
    files: files,
    coverFile: coverFile,
    metadata: metadata ?? this.metadata,
    embeddedCoverBytes: embeddedCoverBytes ?? this.embeddedCoverBytes,
    embeddedCoverMimeType: embeddedCoverMimeType ?? this.embeddedCoverMimeType,
  );
}

/// Groups non-audio media below explicitly configured media roots.
///
/// Each direct child directory is one portable work, including all supported
/// descendants. A file directly below a media root becomes its own work. This
/// keeps arbitrary folders outside those roots untouched and prevents an
/// audiobook's neighboring cover from becoming a separate image work.
final class DocumentImporter {
  DocumentImporter({required Map<String, Iterable<String>> mediaRoots})
    : _roots = [
        for (final entry in mediaRoots.entries)
          for (final root in entry.value)
            if (_supportedKinds.contains(entry.key))
              (kind: _workKind(entry.key), parts: _parts(root)),
      ]..sort((left, right) => right.parts.length.compareTo(left.parts.length));

  static const _supportedKinds = {
    'book',
    'webnovel',
    'manga',
    'image',
    'document',
    'ttrpg_product',
    'archive',
  };
  static const _extensions = {
    'pdf',
    'epub',
    'mobi',
    'azw',
    'azw3',
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
    'tif',
    'tiff',
    'svg',
    'txt',
    'md',
    'html',
    'htm',
    'zip',
    'cbz',
    '7z',
    'rar',
    'tar',
    'gz',
  };
  static const _coverNames = {
    'cover.jpg',
    'cover.jpeg',
    'cover.png',
    'cover.webp',
    'folder.jpg',
    'folder.jpeg',
    'folder.png',
    'folder.webp',
  };

  final List<({String kind, List<String> parts})> _roots;

  List<DocumentImportCandidate> group(Iterable<ScannedFile> files) {
    final grouped = <String, _DocumentGroup>{};
    for (final file in files) {
      if (!_extensions.contains(file.extension)) continue;
      final parts = _parts(file.relativePath);
      final root = _matchingRoot(parts);
      if (root == null || parts.length <= root.parts.length) continue;
      final remainder = parts.sublist(root.parts.length);
      final rootPath = p.posix.joinAll(root.parts);
      final standalone = remainder.length == 1;
      final sourcePath = standalone
          ? file.relativePath
          : p.posix.join(rootPath, remainder.first);
      final title = standalone
          ? p.basenameWithoutExtension(file.filename)
          : remainder.first;
      final key = '${root.kind}\u0000$sourcePath';
      final group = grouped.putIfAbsent(
        key,
        () => _DocumentGroup(
          kind: root.kind,
          sourcePath: sourcePath,
          title: title,
        ),
      );
      group.files.add(file);
    }
    final candidates = [
      for (final group in grouped.values)
        DocumentImportCandidate(
          kind: group.kind,
          directory: group.sourcePath,
          title: group.title,
          files: group.files..sort(_compareFiles),
          coverFile: _cover(group.files, group.kind),
        ),
    ];
    candidates.sort((left, right) {
      final kind = left.kind.compareTo(right.kind);
      return kind != 0
          ? kind
          : left.title.toLowerCase().compareTo(right.title.toLowerCase());
    });
    return candidates;
  }

  ({String kind, List<String> parts})? _matchingRoot(List<String> path) {
    for (final root in _roots) {
      if (root.parts.length >= path.length) continue;
      var matches = true;
      for (var index = 0; index < root.parts.length; index++) {
        if (root.parts[index].toLowerCase() != path[index].toLowerCase()) {
          matches = false;
          break;
        }
      }
      if (matches) return root;
    }
    return null;
  }

  static ScannedFile? _cover(List<ScannedFile> files, String kind) {
    for (final file in files) {
      if (_coverNames.contains(file.filename.toLowerCase())) return file;
    }
    if (kind == 'image') {
      return files
          .where((file) => file.mimeType?.startsWith('image/') ?? false)
          .firstOrNull;
    }
    return null;
  }

  static int _compareFiles(ScannedFile left, ScannedFile right) =>
      _naturalCompare(left.relativePath, right.relativePath);

  static int _naturalCompare(String left, String right) {
    final pattern = RegExp(r'\d+|\D+');
    final leftParts = pattern
        .allMatches(left.toLowerCase())
        .map((match) => match.group(0)!)
        .toList(growable: false);
    final rightParts = pattern
        .allMatches(right.toLowerCase())
        .map((match) => match.group(0)!)
        .toList(growable: false);
    final length = leftParts.length < rightParts.length
        ? leftParts.length
        : rightParts.length;
    for (var index = 0; index < length; index++) {
      final leftPart = leftParts[index];
      final rightPart = rightParts[index];
      final leftNumber = BigInt.tryParse(leftPart);
      final rightNumber = BigInt.tryParse(rightPart);
      final comparison = leftNumber != null && rightNumber != null
          ? leftNumber.compareTo(rightNumber)
          : leftPart.compareTo(rightPart);
      if (comparison != 0) return comparison;
    }
    return leftParts.length.compareTo(rightParts.length);
  }

  static List<String> _parts(String value) => p.posix
      .split(p.posix.normalize(value.replaceAll('\\', '/')))
      .where((part) => part.isNotEmpty && part != '.')
      .toList(growable: false);

  static String _workKind(String configurationKind) =>
      switch (configurationKind) {
        'book' => 'ebook',
        _ => configurationKind,
      };
}

final class _DocumentGroup {
  _DocumentGroup({
    required this.kind,
    required this.sourcePath,
    required this.title,
  });

  final String kind;
  final String sourcePath;
  final String title;
  final List<ScannedFile> files = [];
}
