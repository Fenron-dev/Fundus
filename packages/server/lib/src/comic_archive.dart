import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'};

final class ComicArchivePage {
  const ComicArchivePage({
    required this.id,
    required this.archiveName,
    required this.name,
    required this.size,
    required this.mimeType,
    this.width,
    this.height,
  });

  final String id;
  final String archiveName;
  final String name;
  final int size;
  final String mimeType;
  final int? width;
  final int? height;
}

final class ComicArchiveManifest {
  const ComicArchiveManifest({required this.pages});

  final List<ComicArchivePage> pages;
}

final class ComicArchiveService {
  const ComicArchiveService({
    this.maxArchiveBytes = 1024 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxEntryBytes = 256 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;

  Future<ComicArchiveManifest> inspect(String path) =>
      Isolate.run(() => _inspectSync(path));

  Future<Uint8List> readPage(String path, ComicArchivePage page) =>
      Isolate.run(() => _readPageSync(path, page));

  ComicArchiveManifest _inspectSync(String path) {
    final archive = _open(path);
    try {
      _validateArchive(archive);
      final pages = <ComicArchivePage>[];
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final canonical = _canonicalPath(entry.name);
        final extension = p.extension(canonical).toLowerCase();
        if (!_imageExtensions.contains(extension)) continue;
        final bytes = entry.readBytes() ?? Uint8List(0);
        final dimensions = _imageDimensions(bytes);
        pages.add(
          ComicArchivePage(
            id: canonical,
            archiveName: entry.name,
            name: p.posix.basename(canonical),
            size: entry.size,
            mimeType: _mimeType(extension),
            width: dimensions?.width,
            height: dimensions?.height,
          ),
        );
        // Only dimensions are retained in the manifest. Avoid keeping every
        // decompressed page alive until the complete archive is inspected.
        entry.clear();
      }
      pages.sort((left, right) => _naturalCompare(left.id, right.id));
      return ComicArchiveManifest(pages: List.unmodifiable(pages));
    } finally {
      archive.clearSync();
    }
  }

  Uint8List _readPageSync(String path, ComicArchivePage page) {
    final archive = _open(path);
    try {
      _validateArchive(archive);
      final entry = archive.find(page.archiveName);
      if (entry == null ||
          !entry.isFile ||
          entry.isSymbolicLink ||
          _canonicalPath(entry.name) != page.id ||
          entry.size != page.size ||
          entry.size > maxEntryBytes) {
        throw const ComicArchiveException('comic_page_changed');
      }
      return Uint8List.fromList(entry.readBytes() ?? const []);
    } finally {
      archive.clearSync();
    }
  }

  Archive _open(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw const ComicArchiveException('comic_file_missing');
    }
    if (p.extension(path).toLowerCase() != '.cbz') {
      throw const ComicArchiveException('comic_format_unsupported');
    }
    if (file.lengthSync() > maxArchiveBytes) {
      throw const ComicArchiveException('comic_archive_too_large');
    }
    try {
      return ZipDecoder().decodeStream(InputFileStream(path));
    } catch (_) {
      throw const ComicArchiveException('comic_archive_invalid');
    }
  }

  void _validateArchive(Archive archive) {
    if (archive.length > maxEntries) {
      throw const ComicArchiveException('comic_archive_too_many_entries');
    }
    var total = 0;
    for (final entry in archive) {
      _canonicalPath(entry.name);
      if (entry.isSymbolicLink) {
        throw const ComicArchiveException('comic_archive_symlink');
      }
      if (!entry.isFile) continue;
      if (entry.size > maxEntryBytes) {
        throw const ComicArchiveException('comic_page_too_large');
      }
      total += entry.size;
      if (total > maxTotalBytes) {
        throw const ComicArchiveException('comic_archive_expanded_too_large');
      }
    }
  }

  static String _canonicalPath(String value) {
    final normalized = value
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.contains('\u0000')) {
      throw const ComicArchiveException('comic_archive_unsafe_path');
    }
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const ComicArchiveException('comic_archive_unsafe_path');
    }
    return p.posix.joinAll(parts);
  }
}

final class ComicArchiveException implements Exception {
  const ComicArchiveException(this.code);

  final String code;
}

({int width, int height})? _imageDimensions(Uint8List bytes) {
  if (bytes.length >= 24 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47) {
    return (width: _u32be(bytes, 16), height: _u32be(bytes, 20));
  }
  if (bytes.length >= 10 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return (width: _u16le(bytes, 6), height: _u16le(bytes, 8));
  }
  if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4d) {
    return (width: _u32le(bytes, 18), height: _u32le(bytes, 22));
  }
  if (bytes.length >= 12 && bytes[0] == 0xff && bytes[1] == 0xd8) {
    var offset = 2;
    while (offset + 8 < bytes.length) {
      if (bytes[offset] != 0xff) {
        offset++;
        continue;
      }
      final marker = bytes[offset + 1];
      if ({
        0xc0,
        0xc1,
        0xc2,
        0xc3,
        0xc5,
        0xc6,
        0xc7,
        0xc9,
        0xca,
        0xcb,
        0xcd,
        0xce,
        0xcf,
      }.contains(marker)) {
        return (
          width: _u16be(bytes, offset + 7),
          height: _u16be(bytes, offset + 5),
        );
      }
      if (marker == 0xd8 || marker == 0xd9) {
        offset += 2;
      } else {
        final length = _u16be(bytes, offset + 2);
        if (length < 2) return null;
        offset += 2 + length;
      }
    }
  }
  if (bytes.length >= 30 &&
      String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    final kind = String.fromCharCodes(bytes.sublist(12, 16));
    if (kind == 'VP8X') {
      return (
        width: 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16),
        height: 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16),
      );
    }
    if (kind == 'VP8L' && bytes.length >= 25) {
      final bits = _u32le(bytes, 21);
      return (width: (bits & 0x3fff) + 1, height: ((bits >> 14) & 0x3fff) + 1);
    }
    if (kind == 'VP8 ' &&
        bytes.length >= 30 &&
        bytes[23] == 0x9d &&
        bytes[24] == 0x01 &&
        bytes[25] == 0x2a) {
      return (
        width: _u16le(bytes, 26) & 0x3fff,
        height: _u16le(bytes, 28) & 0x3fff,
      );
    }
  }
  return null;
}

int _u16be(Uint8List bytes, int offset) =>
    (bytes[offset] << 8) | bytes[offset + 1];
int _u16le(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);
int _u32be(Uint8List bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];
int _u32le(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

String _mimeType(String extension) => switch (extension) {
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.png' => 'image/png',
  '.webp' => 'image/webp',
  '.gif' => 'image/gif',
  '.bmp' => 'image/bmp',
  _ => 'application/octet-stream',
};

int _naturalCompare(String left, String right) {
  final leftParts = _naturalParts(left.toLowerCase());
  final rightParts = _naturalParts(right.toLowerCase());
  for (
    var index = 0;
    index < leftParts.length && index < rightParts.length;
    index++
  ) {
    final leftPart = leftParts[index];
    final rightPart = rightParts[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    final comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}

List<String> _naturalParts(String value) => RegExp(
  r'\d+|\D+',
).allMatches(value).map((match) => match.group(0)!).toList();
