import 'dart:io';
import 'dart:typed_data';

enum AudioPlaybackTarget { desktop, android }

enum AudioCompatibilityStatus { compatible, warning, unsupported, unknown }

final class AudioCompatibilityAssessment {
  const AudioCompatibilityAssessment({
    required this.status,
    required this.reason,
  });

  final AudioCompatibilityStatus status;
  final String reason;
}

final class AudioTechnicalMetadata {
  const AudioTechnicalMetadata({
    required this.container,
    required this.codec,
    this.profile,
    this.channels,
    this.sampleRateHz,
  });

  final String container;
  final String codec;
  final String? profile;
  final int? channels;
  final int? sampleRateHz;

  AudioCompatibilityAssessment assess(AudioPlaybackTarget target) {
    final normalizedCodec = codec.toLowerCase();
    if (channels case final value? when value > 8) {
      return const AudioCompatibilityAssessment(
        status: AudioCompatibilityStatus.unsupported,
        reason: 'Mehr als acht Audiokanäle werden nicht unterstützt.',
      );
    }
    if (sampleRateHz case final value? when value > 192000) {
      return const AudioCompatibilityAssessment(
        status: AudioCompatibilityStatus.unsupported,
        reason: 'Die Abtastrate liegt über 192 kHz.',
      );
    }
    const broadlySupported = {'mp3', 'aac', 'flac', 'vorbis', 'opus', 'pcm'};
    if (broadlySupported.contains(normalizedCodec)) {
      return const AudioCompatibilityAssessment(
        status: AudioCompatibilityStatus.compatible,
        reason: 'Das Format wird vom Fundus-Player unterstützt.',
      );
    }
    if (target == AudioPlaybackTarget.desktop && normalizedCodec == 'alac') {
      return const AudioCompatibilityAssessment(
        status: AudioCompatibilityStatus.compatible,
        reason: 'ALAC wird vom Desktop-Player unterstützt.',
      );
    }
    if (normalizedCodec == 'alac') {
      return const AudioCompatibilityAssessment(
        status: AudioCompatibilityStatus.warning,
        reason: 'ALAC kann abhängig vom Android-Gerät nicht abspielbar sein.',
      );
    }
    if ({'ac-3', 'e-ac-3', 'dts'}.contains(normalizedCodec)) {
      return AudioCompatibilityAssessment(
        status: AudioCompatibilityStatus.warning,
        reason: target == AudioPlaybackTarget.android
            ? 'Dieser Codec ist auf Android geräte- und lizenzabhängig.'
            : 'Dieser Codec ist von der installierten Player-Laufzeit abhängig.',
      );
    }
    return AudioCompatibilityAssessment(
      status: AudioCompatibilityStatus.unknown,
      reason:
          'Für den Codec „$codec“ liegt noch kein verlässliches Profil vor.',
    );
  }
}

abstract final class AudioTechnicalMetadataProbe {
  static const _maximumBytes = 256 * 1024;
  static const _maximumMp4MetadataBytes = 64 * 1024 * 1024;

  static Future<AudioTechnicalMetadata?> inspect(
    File file,
    String extension,
    int fileSize,
  ) async {
    if (!_audioExtensions.contains(extension)) return null;
    try {
      final end = fileSize < _maximumBytes ? fileSize : _maximumBytes;
      final bytes = await file
          .openRead(0, end)
          .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk));
      if (fileSize > _maximumBytes) {
        bytes.addAll(
          await file
              .openRead(fileSize - _maximumBytes, fileSize)
              .fold<List<int>>(
                <int>[],
                (buffer, chunk) => buffer..addAll(chunk),
              ),
        );
      }
      final data = Uint8List.fromList(bytes);
      return switch (extension) {
            'mp3' => _mp3(data),
            'm4a' || 'm4b' || 'mp4' =>
              await _mp4FromFile(file, extension, fileSize) ??
                  _mp4(data, extension),
            'wav' => _wav(data),
            'flac' => _flac(data),
            'ogg' || 'opus' => _ogg(data),
            _ => null,
          } ??
          _fallback(extension);
    } on FileSystemException {
      return _fallback(extension);
    }
  }

  static AudioTechnicalMetadata? _mp3(Uint8List bytes) {
    var offset = 0;
    if (bytes.length >= 10 && _ascii(bytes, 0, 3) == 'ID3') {
      offset =
          10 +
          ((bytes[6] & 0x7f) << 21) +
          ((bytes[7] & 0x7f) << 14) +
          ((bytes[8] & 0x7f) << 7) +
          (bytes[9] & 0x7f);
      if (offset >= bytes.length) offset = 10;
    }
    for (var index = offset; index + 3 < bytes.length; index++) {
      if (bytes[index] != 0xff || (bytes[index + 1] & 0xe0) != 0xe0) continue;
      final versionBits = (bytes[index + 1] >> 3) & 0x03;
      final layerBits = (bytes[index + 1] >> 1) & 0x03;
      final sampleRateIndex = (bytes[index + 2] >> 2) & 0x03;
      if (versionBits == 1 || layerBits == 0 || sampleRateIndex == 3) continue;
      final baseRate = const [44100, 48000, 32000][sampleRateIndex];
      final sampleRate = switch (versionBits) {
        3 => baseRate,
        2 => baseRate ~/ 2,
        _ => baseRate ~/ 4,
      };
      final layer = switch (layerBits) {
        3 => 'I',
        2 => 'II',
        _ => 'III',
      };
      return AudioTechnicalMetadata(
        container: 'MP3',
        codec: 'MP3',
        profile: 'MPEG Layer $layer',
        channels: ((bytes[index + 3] >> 6) & 0x03) == 3 ? 1 : 2,
        sampleRateHz: sampleRate,
      );
    }
    return null;
  }

  static AudioTechnicalMetadata? _mp4(Uint8List bytes, String extension) {
    const entries = {
      'mp4a': 'AAC',
      'alac': 'ALAC',
      'Opus': 'Opus',
      'fLaC': 'FLAC',
      'ac-3': 'AC-3',
      'ec-3': 'E-AC-3',
    };
    for (var index = 4; index + 32 <= bytes.length; index++) {
      final type = _ascii(bytes, index, 4);
      final codec = entries[type];
      if (codec == null) continue;
      final boxStart = index - 4;
      final channels = _u16be(bytes, boxStart + 24);
      final sampleRate = _u32be(bytes, boxStart + 32) >> 16;
      final aacConfiguration = codec == 'AAC'
          ? _aacConfiguration(bytes, index)
          : null;
      return AudioTechnicalMetadata(
        container: extension == 'm4b' ? 'M4B' : 'MP4',
        codec: codec,
        profile: aacConfiguration?.profile ?? (codec == 'AAC' ? null : codec),
        channels:
            aacConfiguration?.channels ?? (channels == 0 ? null : channels),
        sampleRateHz:
            aacConfiguration?.sampleRateHz ??
            (sampleRate == 0 ? null : sampleRate),
      );
    }
    return null;
  }

  /// Reads MP4 atoms without loading or walking through the media payload.
  ///
  /// Large M4B files commonly put `moov` several megabytes before the end of
  /// the file. Reading fixed head/tail windows therefore misses the audio
  /// sample entry even though the file is valid. Top-level atom sizes let us
  /// seek over `mdat` and read only the comparatively small metadata atom.
  static Future<AudioTechnicalMetadata?> _mp4FromFile(
    File file,
    String extension,
    int fileSize,
  ) async {
    final input = await file.open();
    try {
      var offset = 0;
      while (offset + 8 <= fileSize) {
        await input.setPosition(offset);
        final header = await input.read(16);
        if (header.length < 8) return null;
        final headerBytes = Uint8List.fromList(header);
        final type = _ascii(headerBytes, 4, 4);
        var headerSize = 8;
        var atomSize = _u32be(headerBytes, 0);
        if (atomSize == 1) {
          if (header.length < 16) return null;
          headerSize = 16;
          atomSize = _u64be(headerBytes, 8);
        } else if (atomSize == 0) {
          atomSize = fileSize - offset;
        }
        if (atomSize < headerSize || offset + atomSize > fileSize) return null;

        if (type == 'moov' && atomSize <= _maximumMp4MetadataBytes) {
          await input.setPosition(offset);
          final atom = await input.read(atomSize);
          if (atom.length != atomSize) return null;
          return _mp4(Uint8List.fromList(atom), extension);
        }
        offset += atomSize;
      }
      return null;
    } finally {
      await input.close();
    }
  }

  static _AacConfiguration? _aacConfiguration(Uint8List bytes, int start) {
    final end = (start + 4096).clamp(0, bytes.length);
    for (var index = start; index + 2 < end; index++) {
      if (bytes[index] != 0x05) continue;
      var cursor = index + 1;
      var length = 0;
      var lengthBytes = 0;
      while (cursor < end && lengthBytes < 4) {
        final value = bytes[cursor++];
        length = (length << 7) | (value & 0x7f);
        lengthBytes++;
        if ((value & 0x80) == 0) break;
      }
      if (length == 0 || cursor + length > end) continue;
      final configuration = _parseAudioSpecificConfig(
        Uint8List.sublistView(bytes, cursor, cursor + length),
      );
      if (configuration != null) return configuration;
    }
    return null;
  }

  static _AacConfiguration? _parseAudioSpecificConfig(Uint8List bytes) {
    if (bytes.length < 2) return null;
    final reader = _BitReader(bytes);
    var objectType = reader.read(5);
    if (objectType == 31) objectType = 32 + reader.read(6);
    var sampleRate = _aacSampleRate(reader);
    final channelConfiguration = reader.read(4);
    if (objectType == 5 || objectType == 29) {
      final extensionSampleRate = _aacSampleRate(reader);
      if (extensionSampleRate != null) sampleRate = extensionSampleRate;
    }
    return _AacConfiguration(
      profile: switch (objectType) {
        2 => 'AAC-LC',
        5 => 'HE-AAC',
        29 => 'HE-AAC v2',
        _ => 'AAC Object Type $objectType',
      },
      channels: switch (channelConfiguration) {
        1 => 1,
        >= 2 && <= 6 => channelConfiguration,
        7 => 8,
        _ => null,
      },
      sampleRateHz: sampleRate,
    );
  }

  static int? _aacSampleRate(_BitReader reader) {
    const rates = [
      96000,
      88200,
      64000,
      48000,
      44100,
      32000,
      24000,
      22050,
      16000,
      12000,
      11025,
      8000,
      7350,
    ];
    final index = reader.read(4);
    if (index == 15) return reader.read(24);
    return index < rates.length ? rates[index] : null;
  }

  static AudioTechnicalMetadata? _wav(Uint8List bytes) {
    if (bytes.length < 12 ||
        _ascii(bytes, 0, 4) != 'RIFF' ||
        _ascii(bytes, 8, 4) != 'WAVE') {
      return null;
    }
    for (var index = 12; index + 24 <= bytes.length;) {
      final type = _ascii(bytes, index, 4);
      final length = _u32le(bytes, index + 4);
      if (type == 'fmt ' && length >= 16 && index + 24 <= bytes.length) {
        final format = _u16le(bytes, index + 8);
        return AudioTechnicalMetadata(
          container: 'WAV',
          codec: format == 1 || format == 3 ? 'PCM' : 'WAV Format $format',
          profile: format == 3 ? 'IEEE Float' : 'PCM',
          channels: _u16le(bytes, index + 10),
          sampleRateHz: _u32le(bytes, index + 12),
        );
      }
      index += 8 + length + (length.isOdd ? 1 : 0);
    }
    return null;
  }

  static AudioTechnicalMetadata? _flac(Uint8List bytes) {
    if (bytes.length < 22 || _ascii(bytes, 0, 4) != 'fLaC') return null;
    var index = 4;
    while (index + 4 <= bytes.length) {
      final type = bytes[index] & 0x7f;
      final length =
          (bytes[index + 1] << 16) | (bytes[index + 2] << 8) | bytes[index + 3];
      final payload = index + 4;
      if (type == 0 && length >= 18 && payload + 18 <= bytes.length) {
        final sampleRate =
            (bytes[payload + 10] << 12) |
            (bytes[payload + 11] << 4) |
            (bytes[payload + 12] >> 4);
        final channels = ((bytes[payload + 12] >> 1) & 0x07) + 1;
        final bitsPerSample =
            (((bytes[payload + 12] & 0x01) << 4) | (bytes[payload + 13] >> 4)) +
            1;
        return AudioTechnicalMetadata(
          container: 'FLAC',
          codec: 'FLAC',
          profile: '$bitsPerSample Bit',
          channels: channels,
          sampleRateHz: sampleRate,
        );
      }
      index = payload + length;
    }
    return null;
  }

  static AudioTechnicalMetadata? _ogg(Uint8List bytes) {
    final opus = _indexOf(bytes, 'OpusHead'.codeUnits);
    if (opus >= 0 && opus + 10 <= bytes.length) {
      return AudioTechnicalMetadata(
        container: 'Ogg',
        codec: 'Opus',
        profile: 'Opus',
        channels: bytes[opus + 9],
        sampleRateHz: 48000,
      );
    }
    final vorbis = _indexOf(bytes, [1, ...'vorbis'.codeUnits]);
    if (vorbis >= 0 && vorbis + 16 <= bytes.length) {
      return AudioTechnicalMetadata(
        container: 'Ogg',
        codec: 'Vorbis',
        profile: 'Vorbis',
        channels: bytes[vorbis + 11],
        sampleRateHz: _u32le(bytes, vorbis + 12),
      );
    }
    return null;
  }

  static AudioTechnicalMetadata? _fallback(
    String extension,
  ) => switch (extension) {
    'mp3' => const AudioTechnicalMetadata(container: 'MP3', codec: 'MP3'),
    'm4a' || 'm4b' => AudioTechnicalMetadata(
      container: extension.toUpperCase(),
      codec: 'Unbekannt',
    ),
    'flac' => const AudioTechnicalMetadata(container: 'FLAC', codec: 'FLAC'),
    'ogg' => const AudioTechnicalMetadata(container: 'Ogg', codec: 'Unbekannt'),
    'opus' => const AudioTechnicalMetadata(container: 'Ogg', codec: 'Opus'),
    'wav' => const AudioTechnicalMetadata(container: 'WAV', codec: 'PCM'),
    _ => null,
  };

  static String _ascii(Uint8List bytes, int offset, int length) {
    if (offset < 0 || offset + length > bytes.length) return '';
    return String.fromCharCodes(bytes.sublist(offset, offset + length));
  }

  static int _u16be(Uint8List bytes, int offset) =>
      offset + 2 > bytes.length ? 0 : (bytes[offset] << 8) | bytes[offset + 1];

  static int _u16le(Uint8List bytes, int offset) =>
      offset + 2 > bytes.length ? 0 : bytes[offset] | (bytes[offset + 1] << 8);

  static int _u32be(Uint8List bytes, int offset) => offset + 4 > bytes.length
      ? 0
      : (bytes[offset] << 24) |
            (bytes[offset + 1] << 16) |
            (bytes[offset + 2] << 8) |
            bytes[offset + 3];

  static int _u32le(Uint8List bytes, int offset) => offset + 4 > bytes.length
      ? 0
      : bytes[offset] |
            (bytes[offset + 1] << 8) |
            (bytes[offset + 2] << 16) |
            (bytes[offset + 3] << 24);

  static int _u64be(Uint8List bytes, int offset) {
    if (offset + 8 > bytes.length) return 0;
    var value = 0;
    for (var index = 0; index < 8; index++) {
      value = (value << 8) | bytes[offset + index];
    }
    return value;
  }

  static int _indexOf(Uint8List bytes, List<int> pattern) {
    for (var index = 0; index + pattern.length <= bytes.length; index++) {
      var matches = true;
      for (var inner = 0; inner < pattern.length; inner++) {
        if (bytes[index + inner] != pattern[inner]) {
          matches = false;
          break;
        }
      }
      if (matches) return index;
    }
    return -1;
  }
}

final class _AacConfiguration {
  const _AacConfiguration({
    required this.profile,
    required this.channels,
    required this.sampleRateHz,
  });

  final String profile;
  final int? channels;
  final int? sampleRateHz;
}

final class _BitReader {
  _BitReader(this.bytes);

  final Uint8List bytes;
  int _offset = 0;

  int read(int count) {
    var value = 0;
    for (var index = 0; index < count; index++) {
      value <<= 1;
      final byteOffset = _offset >> 3;
      if (byteOffset < bytes.length) {
        value |= (bytes[byteOffset] >> (7 - (_offset & 7))) & 1;
      }
      _offset++;
    }
    return value;
  }
}

const _audioExtensions = {'mp3', 'm4a', 'm4b', 'flac', 'ogg', 'opus', 'wav'};
