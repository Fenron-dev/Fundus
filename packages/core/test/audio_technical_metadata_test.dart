import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reads MPEG profile channels and sample rate from an MP3 frame',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fundus-mp3-probe-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/track.mp3');
      await file.writeAsBytes([0xff, 0xfb, 0x90, 0x64, ...List.filled(32, 0)]);

      final metadata = await AudioTechnicalMetadataProbe.inspect(
        file,
        'mp3',
        await file.length(),
      );

      expect(metadata, isNotNull);
      expect(metadata!.container, 'MP3');
      expect(metadata.codec, 'MP3');
      expect(metadata.profile, 'MPEG Layer III');
      expect(metadata.channels, 2);
      expect(metadata.sampleRateHz, 44100);
      expect(
        metadata.assess(AudioPlaybackTarget.android).status,
        AudioCompatibilityStatus.compatible,
      );
    },
  );

  test('marks ALAC as an Android compatibility warning', () {
    const metadata = AudioTechnicalMetadata(
      container: 'M4B',
      codec: 'ALAC',
      profile: 'ALAC',
      channels: 2,
      sampleRateHz: 48000,
    );

    expect(
      metadata.assess(AudioPlaybackTarget.desktop).status,
      AudioCompatibilityStatus.compatible,
    );
    final android = metadata.assess(AudioPlaybackTarget.android);
    expect(android.status, AudioCompatibilityStatus.warning);
    expect(android.reason, contains('Android-Gerät'));
  });

  test('finds an MP4 audio sample entry stored at the end of an M4B', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fundus-m4b-tail-probe-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final sampleEntry = List<int>.filled(43, 0);
    sampleEntry.setAll(0, [0, 0, 0, 43, ...'mp4a'.codeUnits]);
    sampleEntry.setAll(24, [0, 2]);
    sampleEntry.setAll(32, [0xac, 0x44, 0, 0]);
    sampleEntry.setAll(36, [0x05, 0x80, 0x80, 0x80, 0x02, 0x12, 0x10]);
    final file = File('${directory.path}/book.m4b');
    await file.writeAsBytes([...List.filled(300000, 0), ...sampleEntry]);

    final metadata = await AudioTechnicalMetadataProbe.inspect(
      file,
      'm4b',
      await file.length(),
    );

    expect(metadata?.container, 'M4B');
    expect(metadata?.codec, 'AAC');
    expect(metadata?.profile, 'AAC-LC');
    expect(metadata?.channels, 2);
    expect(metadata?.sampleRateHz, 44100);
  });

  test(
    'seeks to a moov atom outside the fixed head and tail windows',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fundus-m4b-moov-probe-',
      );
      addTearDown(() => directory.delete(recursive: true));

      List<int> atom(String type, List<int> payload) {
        final size = payload.length + 8;
        return [
          (size >> 24) & 0xff,
          (size >> 16) & 0xff,
          (size >> 8) & 0xff,
          size & 0xff,
          ...type.codeUnits,
          ...payload,
        ];
      }

      final sampleEntry = List<int>.filled(36, 0);
      sampleEntry.setAll(0, [0, 0, 0, 36, ...'mp4a'.codeUnits]);
      sampleEntry.setAll(24, [0, 2]);
      sampleEntry.setAll(32, [0xac, 0x44, 0, 0]);
      final file = File('${directory.path}/book.m4b');
      await file.writeAsBytes([
        ...atom('ftyp', 'M4B '.codeUnits),
        ...atom('mdat', List<int>.filled(600000, 0)),
        ...atom('moov', sampleEntry),
        ...atom('free', List<int>.filled(300000, 0)),
      ]);

      final metadata = await AudioTechnicalMetadataProbe.inspect(
        file,
        'm4b',
        await file.length(),
      );

      expect(metadata?.container, 'M4B');
      expect(metadata?.codec, 'AAC');
      expect(metadata?.channels, 2);
      expect(metadata?.sampleRateHz, 44100);
    },
  );
}
