import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final class EmbeddedCover {
  const EmbeddedCover({
    required this.bytes,
    required this.extension,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String extension;
  final String mimeType;
}

final class EmbeddedAudioChapter {
  const EmbeddedAudioChapter({required this.title, required this.position});

  final String title;
  final Duration position;
}

final class EmbeddedAudioMetadata {
  const EmbeddedAudioMetadata({
    this.title,
    this.album,
    this.author,
    this.albumArtist,
    this.series,
    this.part,
    this.language,
  });

  final String? title;
  final String? album;
  final String? author;
  final String? albumArtist;
  final String? series;
  final double? part;
  final String? language;

  bool get isEmpty =>
      title == null &&
      album == null &&
      author == null &&
      albumArtist == null &&
      series == null &&
      part == null &&
      language == null;
}

/// Reads common embedded audiobook artwork without loading the complete audio
/// file into memory. M4A/M4B `covr` atoms and MP3 ID3 `APIC` frames are
/// supported; callers can fall back to a neighboring cover image otherwise.
final class EmbeddedCoverExtractor {
  const EmbeddedCoverExtractor();

  static const _maximumCoverBytes = 32 * 1024 * 1024;

  Future<EmbeddedCover?> extract(File file) async {
    final extension = file.path.split('.').last.toLowerCase();
    return switch (extension) {
      'm4a' || 'm4b' || 'mp4' => _extractMp4(file),
      'mp3' => _extractMp3(file),
      _ => null,
    };
  }

  Future<String?> extractLanguage(File file) async {
    final extension = file.path.split('.').last.toLowerCase();
    return switch (extension) {
      'm4a' || 'm4b' || 'mp4' => _extractMp4Language(file),
      'mp3' => _extractMp3Language(file),
      _ => null,
    };
  }

  /// Reads only the small, explicitly supported identity field set. Unknown
  /// MP4/ID3 fields are deliberately ignored and never persisted by Fundus.
  Future<EmbeddedAudioMetadata> extractMetadata(File file) async {
    final extension = file.path.split('.').last.toLowerCase();
    return switch (extension) {
      'm4a' || 'm4b' || 'mp4' => _extractMp4Metadata(file),
      'mp3' => _extractMp3Metadata(file),
      _ => const EmbeddedAudioMetadata(),
    };
  }

  Future<EmbeddedAudioMetadata> _extractMp4Metadata(File file) async {
    final input = await file.open();
    try {
      final values = <String, String>{};
      await _walkMp4Metadata(input, 0, await input.length(), values, depth: 0);
      return EmbeddedAudioMetadata(
        title: values['title'],
        album: values['album'],
        author: values['artist'],
        albumArtist: values['album_artist'],
        series: values['series'],
        part: _parsePart(values['part']),
        language: values['language'],
      );
    } finally {
      await input.close();
    }
  }

  Future<void> _walkMp4Metadata(
    RandomAccessFile input,
    int start,
    int end,
    Map<String, String> values, {
    required int depth,
    String? parentType,
  }) async {
    if (depth > 12 || start < 0 || end <= start) return;
    var offset = start;
    while (offset + 8 <= end) {
      await input.setPosition(offset);
      final header = await input.read(8);
      if (header.length != 8) return;
      var size = _uint32(header, 0);
      final type = latin1.decode(header.sublist(4, 8), allowInvalid: true);
      var headerSize = 8;
      if (size == 1) {
        final extended = await input.read(8);
        if (extended.length != 8) return;
        size = _uint64(extended, 0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) return;
      var payloadStart = offset + headerSize;
      final atomEnd = offset + size;

      if (parentType == 'ilst') {
        final key = switch (type) {
          '©nam' => 'title',
          '©alb' => 'album',
          '©ART' => 'artist',
          'aART' => 'album_artist',
          '©lan' => 'language',
          _ => null,
        };
        if (key != null) {
          final value = await _readMp4TextTag(input, payloadStart, atomEnd);
          if (value != null) values.putIfAbsent(key, () => value);
        } else if (type == '----') {
          final freeform = await _readMp4FreeformTag(
            input,
            payloadStart,
            atomEnd,
          );
          if (freeform case (name: final name, value: final value)) {
            final key = switch (name.toUpperCase()) {
              'SERIES' => 'series',
              'PART' => 'part',
              'LANGUAGE' => 'language',
              _ => null,
            };
            if (key != null) values.putIfAbsent(key, () => value);
          }
        }
      }

      const containers = {'moov', 'udta', 'meta', 'ilst'};
      if (containers.contains(type)) {
        if (type == 'meta') payloadStart += 4;
        await _walkMp4Metadata(
          input,
          payloadStart,
          atomEnd,
          values,
          depth: depth + 1,
          parentType: type,
        );
      }
      offset = atomEnd;
    }
  }

  Future<String?> _readMp4TextTag(
    RandomAccessFile input,
    int start,
    int end,
  ) async {
    final children = await _readMp4ChildPayloads(input, start, end);
    return _cleanText(children['data']);
  }

  Future<({String name, String value})?> _readMp4FreeformTag(
    RandomAccessFile input,
    int start,
    int end,
  ) async {
    final children = await _readMp4ChildPayloads(input, start, end);
    final name = _cleanText(children['name']);
    final value = _cleanText(children['data']);
    return name == null || value == null ? null : (name: name, value: value);
  }

  Future<Map<String, List<int>>> _readMp4ChildPayloads(
    RandomAccessFile input,
    int start,
    int end,
  ) async {
    final result = <String, List<int>>{};
    var offset = start;
    while (offset + 8 <= end) {
      await input.setPosition(offset);
      final header = await input.read(8);
      if (header.length != 8) break;
      final size = _uint32(header, 0);
      final type = latin1.decode(header.sublist(4, 8), allowInvalid: true);
      if (size < 12 || offset + size > end) break;
      final payloadLength = size - 12;
      if (payloadLength > 4096) {
        offset += size;
        continue;
      }
      await input.setPosition(offset + 12);
      var bytes = await input.read(payloadLength);
      if (type == 'data' && bytes.length >= 4) bytes = bytes.sublist(4);
      result.putIfAbsent(type, () => bytes);
      offset += size;
    }
    return result;
  }

  Future<EmbeddedAudioMetadata> _extractMp3Metadata(File file) async {
    final input = await file.open();
    try {
      final header = await input.read(10);
      if (header.length != 10 || ascii.decode(header.sublist(0, 3)) != 'ID3') {
        return const EmbeddedAudioMetadata();
      }
      final version = header[3];
      if (version != 3 && version != 4) return const EmbeddedAudioMetadata();
      var remaining = _synchsafe(header, 6);
      final values = <String, String>{};
      while (remaining >= 10) {
        final frameHeader = await input.read(10);
        if (frameHeader.length != 10) break;
        remaining -= 10;
        if (frameHeader.every((value) => value == 0)) break;
        final id = ascii.decode(frameHeader.sublist(0, 4), allowInvalid: true);
        final size = version == 4
            ? _synchsafe(frameHeader, 4)
            : _uint32(frameHeader, 4);
        if (size <= 0 || size > remaining) break;
        if (const {'TIT2', 'TALB', 'TPE1', 'TPE2', 'TLAN'}.contains(id) &&
            size <= 4096) {
          final value = _decodeId3Text(await input.read(size));
          final key = switch (id) {
            'TIT2' => 'title',
            'TALB' => 'album',
            'TPE1' => 'artist',
            'TPE2' => 'album_artist',
            'TLAN' => 'language',
            _ => '',
          };
          if (value != null) values.putIfAbsent(key, () => value);
        } else if (id == 'TXXX' && size <= 4096) {
          final value = _decodeId3UserText(await input.read(size));
          if (value != null) {
            final key = switch (value.name.toUpperCase()) {
              'SERIES' => 'series',
              'PART' => 'part',
              'LANGUAGE' => 'language',
              _ => null,
            };
            if (key != null) values.putIfAbsent(key, () => value.value);
          }
        } else {
          await input.setPosition(await input.position() + size);
        }
        remaining -= size;
      }
      return EmbeddedAudioMetadata(
        title: values['title'],
        album: values['album'],
        author: values['artist'],
        albumArtist: values['album_artist'],
        series: values['series'],
        part: _parsePart(values['part']),
        language: values['language'],
      );
    } finally {
      await input.close();
    }
  }

  /// Reads Nero-style `chpl` chapter atoms used by M4A/M4B audiobooks.
  /// Timestamps are stored in 100-nanosecond units.
  Future<List<EmbeddedAudioChapter>> extractChapters(File file) async {
    final extension = file.path.split('.').last.toLowerCase();
    if (extension != 'm4a' && extension != 'm4b' && extension != 'mp4') {
      return const [];
    }
    final input = await file.open();
    try {
      return await _walkMp4Chapters(input, 0, await input.length(), depth: 0);
    } finally {
      await input.close();
    }
  }

  Future<List<EmbeddedAudioChapter>> _walkMp4Chapters(
    RandomAccessFile input,
    int start,
    int end, {
    required int depth,
  }) async {
    if (depth > 12 || start < 0 || end <= start) return const [];
    var offset = start;
    while (offset + 8 <= end) {
      await input.setPosition(offset);
      final header = await input.read(8);
      if (header.length != 8) return const [];
      var size = _uint32(header, 0);
      final type = latin1.decode(header.sublist(4, 8), allowInvalid: true);
      var headerSize = 8;
      if (size == 1) {
        final extended = await input.read(8);
        if (extended.length != 8) return const [];
        size = _uint64(extended, 0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) return const [];

      final payloadStart = offset + headerSize;
      final atomEnd = offset + size;
      if (type == 'chpl') {
        return _readChapterAtom(input, payloadStart, atomEnd);
      }
      const containers = {'moov', 'udta', 'meta'};
      if (containers.contains(type)) {
        final childStart = payloadStart + (type == 'meta' ? 4 : 0);
        final chapters = await _walkMp4Chapters(
          input,
          childStart,
          atomEnd,
          depth: depth + 1,
        );
        if (chapters.isNotEmpty) return chapters;
      }
      offset = atomEnd;
    }
    return const [];
  }

  Future<List<EmbeddedAudioChapter>> _readChapterAtom(
    RandomAccessFile input,
    int start,
    int end,
  ) async {
    if (end - start < 5) return const [];
    await input.setPosition(start);
    final fullBox = await input.read(4);
    if (fullBox.length != 4) return const [];
    final version = fullBox.first;
    if (version != 0) {
      if (await input.position() + 4 > end) return const [];
      await input.setPosition(await input.position() + 4);
    }
    final countBytes = await input.read(1);
    if (countBytes.length != 1) return const [];
    final chapters = <EmbeddedAudioChapter>[];
    for (var index = 0; index < countBytes.first; index++) {
      if (await input.position() + 9 > end) return const [];
      final timestamp = await input.read(8);
      final titleLengthBytes = await input.read(1);
      if (timestamp.length != 8 || titleLengthBytes.length != 1) {
        return const [];
      }
      final titleLength = titleLengthBytes.first;
      if (await input.position() + titleLength > end) return const [];
      final titleBytes = await input.read(titleLength);
      final title = utf8.decode(titleBytes, allowMalformed: true).trim();
      final timestamp100Nanoseconds = _uint64(timestamp, 0);
      chapters.add(
        EmbeddedAudioChapter(
          title: title.isEmpty ? 'Kapitel ${index + 1}' : title,
          position: Duration(microseconds: timestamp100Nanoseconds ~/ 10),
        ),
      );
    }
    return chapters;
  }

  Future<EmbeddedCover?> _extractMp4(File file) async {
    final input = await file.open();
    try {
      final length = await input.length();
      return await _walkMp4Atoms(input, 0, length, depth: 0);
    } finally {
      await input.close();
    }
  }

  Future<EmbeddedCover?> _walkMp4Atoms(
    RandomAccessFile input,
    int start,
    int end, {
    required int depth,
    String? parentType,
  }) async {
    if (depth > 12 || start < 0 || end <= start) return null;
    var offset = start;
    while (offset + 8 <= end) {
      await input.setPosition(offset);
      final header = await input.read(8);
      if (header.length != 8) return null;
      var size = _uint32(header, 0);
      final type = latin1.decode(header.sublist(4, 8), allowInvalid: true);
      var headerSize = 8;
      if (size == 1) {
        final extended = await input.read(8);
        if (extended.length != 8) return null;
        size = _uint64(extended, 0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) return null;

      var payloadStart = offset + headerSize;
      final atomEnd = offset + size;
      if (type == 'data' && parentType == 'covr') {
        final metadataSize = atomEnd - payloadStart;
        if (metadataSize <= 8 || metadataSize > _maximumCoverBytes + 8) {
          return null;
        }
        await input.setPosition(payloadStart + 8);
        final bytes = await input.read(metadataSize - 8);
        return _identify(bytes);
      }

      const containers = {'moov', 'udta', 'meta', 'ilst', 'covr'};
      if (containers.contains(type)) {
        // `meta` is a full box and has version/flags before its child atoms.
        if (type == 'meta') payloadStart += 4;
        final result = await _walkMp4Atoms(
          input,
          payloadStart,
          atomEnd,
          depth: depth + 1,
          parentType: type,
        );
        if (result != null) return result;
      }
      offset = atomEnd;
    }
    return null;
  }

  Future<EmbeddedCover?> _extractMp3(File file) async {
    final input = await file.open();
    try {
      final header = await input.read(10);
      if (header.length != 10 || ascii.decode(header.sublist(0, 3)) != 'ID3') {
        return null;
      }
      final version = header[3];
      if (version != 3 && version != 4) return null;
      final tagSize = _synchsafe(header, 6);
      var remaining = tagSize;
      while (remaining >= 10) {
        final frameHeader = await input.read(10);
        if (frameHeader.length != 10) return null;
        remaining -= 10;
        final id = ascii.decode(frameHeader.sublist(0, 4), allowInvalid: true);
        if (frameHeader.every((value) => value == 0)) return null;
        final size = version == 4
            ? _synchsafe(frameHeader, 4)
            : _uint32(frameHeader, 4);
        if (size <= 0 || size > remaining) return null;
        if (id == 'APIC') {
          if (size > _maximumCoverBytes + 1024) return null;
          final payload = await input.read(size);
          return _identifyFromPayload(payload);
        }
        await input.setPosition(await input.position() + size);
        remaining -= size;
      }
      return null;
    } finally {
      await input.close();
    }
  }

  Future<String?> _extractMp4Language(File file) async {
    final input = await file.open();
    try {
      return await _walkMp4Language(input, 0, await input.length(), depth: 0);
    } finally {
      await input.close();
    }
  }

  Future<String?> _walkMp4Language(
    RandomAccessFile input,
    int start,
    int end, {
    required int depth,
    String? parentType,
  }) async {
    if (depth > 12 || start < 0 || end <= start) return null;
    var offset = start;
    while (offset + 8 <= end) {
      await input.setPosition(offset);
      final header = await input.read(8);
      if (header.length != 8) return null;
      var size = _uint32(header, 0);
      final type = latin1.decode(header.sublist(4, 8), allowInvalid: true);
      var headerSize = 8;
      if (size == 1) {
        final extended = await input.read(8);
        if (extended.length != 8) return null;
        size = _uint64(extended, 0);
        headerSize = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < headerSize || offset + size > end) return null;
      var payloadStart = offset + headerSize;
      final atomEnd = offset + size;
      if (type == 'data' && parentType == '©lan') {
        final payloadSize = atomEnd - payloadStart;
        if (payloadSize <= 8 || payloadSize > 264) return null;
        await input.setPosition(payloadStart + 8);
        final value = utf8
            .decode(await input.read(payloadSize - 8), allowMalformed: true)
            .replaceAll('\u0000', '')
            .trim();
        return value.isEmpty ? null : value;
      }
      const containers = {'moov', 'udta', 'meta', 'ilst', '©lan'};
      if (containers.contains(type)) {
        if (type == 'meta') payloadStart += 4;
        final value = await _walkMp4Language(
          input,
          payloadStart,
          atomEnd,
          depth: depth + 1,
          parentType: type,
        );
        if (value != null) return value;
      }
      offset = atomEnd;
    }
    return null;
  }

  Future<String?> _extractMp3Language(File file) async {
    final input = await file.open();
    try {
      final header = await input.read(10);
      if (header.length != 10 || ascii.decode(header.sublist(0, 3)) != 'ID3') {
        return null;
      }
      final version = header[3];
      if (version != 3 && version != 4) return null;
      var remaining = _synchsafe(header, 6);
      while (remaining >= 10) {
        final frameHeader = await input.read(10);
        if (frameHeader.length != 10) return null;
        remaining -= 10;
        final id = ascii.decode(frameHeader.sublist(0, 4), allowInvalid: true);
        if (frameHeader.every((value) => value == 0)) return null;
        final size = version == 4
            ? _synchsafe(frameHeader, 4)
            : _uint32(frameHeader, 4);
        if (size <= 0 || size > remaining) return null;
        if (id == 'TLAN' && size <= 256) {
          final payload = await input.read(size);
          return _decodeId3Text(payload);
        }
        await input.setPosition(await input.position() + size);
        remaining -= size;
      }
      return null;
    } finally {
      await input.close();
    }
  }

  static String? _decodeId3Text(List<int> payload) {
    if (payload.length < 2) return null;
    final encoding = payload.first;
    final bytes = payload.sublist(1);
    String value;
    if (encoding == 0) {
      value = latin1.decode(bytes, allowInvalid: true);
    } else if (encoding == 3) {
      value = utf8.decode(bytes, allowMalformed: true);
    } else if (encoding == 1 || encoding == 2) {
      var offset = 0;
      var littleEndian = false;
      if (encoding == 1 && bytes.length >= 2) {
        if (bytes[0] == 0xff && bytes[1] == 0xfe) {
          littleEndian = true;
          offset = 2;
        } else if (bytes[0] == 0xfe && bytes[1] == 0xff) {
          offset = 2;
        }
      }
      final codeUnits = <int>[];
      for (var index = offset; index + 1 < bytes.length; index += 2) {
        codeUnits.add(
          littleEndian
              ? bytes[index] | (bytes[index + 1] << 8)
              : (bytes[index] << 8) | bytes[index + 1],
        );
      }
      value = String.fromCharCodes(codeUnits);
    } else {
      return null;
    }
    value = value.replaceAll('\u0000', '').trim();
    return value.isEmpty ? null : value;
  }

  static ({String name, String value})? _decodeId3UserText(List<int> payload) {
    if (payload.length < 3) return null;
    final encoding = payload.first;
    final bytes = payload.sublist(1);
    final width = encoding == 1 || encoding == 2 ? 2 : 1;
    int? separator;
    for (var index = 0; index + width <= bytes.length; index += width) {
      final isSeparator = width == 1
          ? bytes[index] == 0
          : bytes[index] == 0 && bytes[index + 1] == 0;
      if (isSeparator) {
        separator = index;
        break;
      }
    }
    if (separator == null) return null;
    var valueBytes = bytes.sublist(separator + width);
    if (encoding == 1 &&
        bytes.length >= 2 &&
        valueBytes.length >= 2 &&
        !((valueBytes[0] == 0xff && valueBytes[1] == 0xfe) ||
            (valueBytes[0] == 0xfe && valueBytes[1] == 0xff))) {
      valueBytes = [bytes[0], bytes[1], ...valueBytes];
    }
    final name = _decodeId3Text([encoding, ...bytes.sublist(0, separator)]);
    final value = _decodeId3Text([encoding, ...valueBytes]);
    return name == null || value == null ? null : (name: name, value: value);
  }

  static String? _cleanText(List<int>? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    final value = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\u0000', '')
        .trim();
    return value.isEmpty ? null : value;
  }

  static double? _parsePart(String? value) {
    if (value == null) return null;
    final match = RegExp(r'\d+(?:[.,]\d+)?').firstMatch(value);
    return match == null
        ? null
        : double.tryParse(match.group(0)!.replaceAll(',', '.'));
  }

  static EmbeddedCover? _identifyFromPayload(List<int> payload) {
    for (var index = 0; index < payload.length - 8; index++) {
      final jpeg =
          payload[index] == 0xff &&
          payload[index + 1] == 0xd8 &&
          payload[index + 2] == 0xff;
      final png =
          payload[index] == 0x89 &&
          payload[index + 1] == 0x50 &&
          payload[index + 2] == 0x4e &&
          payload[index + 3] == 0x47;
      if (jpeg || png) return _identify(payload.sublist(index));
    }
    return null;
  }

  static EmbeddedCover? _identify(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return EmbeddedCover(
        bytes: Uint8List.fromList(bytes),
        extension: 'jpg',
        mimeType: 'image/jpeg',
      );
    }
    const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
    if (bytes.length >= png.length && _startsWith(bytes, png)) {
      return EmbeddedCover(
        bytes: Uint8List.fromList(bytes),
        extension: 'png',
        mimeType: 'image/png',
      );
    }
    return null;
  }

  static bool _startsWith(List<int> bytes, List<int> signature) {
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static int _uint32(List<int> bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _uint64(List<int> bytes, int offset) {
    var value = 0;
    for (var index = 0; index < 8; index++) {
      value = (value << 8) | bytes[offset + index];
    }
    return value;
  }

  static int _synchsafe(List<int> bytes, int offset) =>
      (bytes[offset] << 21) |
      (bytes[offset + 1] << 14) |
      (bytes[offset + 2] << 7) |
      bytes[offset + 3];
}
