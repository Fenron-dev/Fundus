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
