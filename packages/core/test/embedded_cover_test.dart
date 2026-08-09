import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('extracts JPEG artwork from an M4B covr atom', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-cover-');
    addTearDown(() => directory.delete(recursive: true));
    final jpeg = Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xe0,
      0x01,
      0x02,
      0xff,
      0xd9,
    ]);
    final file = File('${directory.path}/book.m4b');
    await file.writeAsBytes(
      _atom('moov', [
        ..._atom('udta', [
          ..._atom('meta', [
            0,
            0,
            0,
            0,
            ..._atom('ilst', [
              ..._atom('covr', [
                ..._atom('data', [0, 0, 0, 13, 0, 0, 0, 0, ...jpeg]),
              ]),
              ..._atom('©lan', [
                ..._atom('data', [
                  0,
                  0,
                  0,
                  1,
                  0,
                  0,
                  0,
                  0,
                  ...'de-DE'.codeUnits,
                ]),
              ]),
            ]),
          ]),
        ]),
      ]),
    );

    final cover = await const EmbeddedCoverExtractor().extract(file);

    expect(cover, isNotNull);
    expect(cover!.extension, 'jpg');
    expect(cover.mimeType, 'image/jpeg');
    expect(cover.bytes, jpeg);
    expect(await const EmbeddedCoverExtractor().extractLanguage(file), 'de-DE');
  });

  test('extracts UTF-16 language from an MP3 TLAN frame', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-language-');
    addTearDown(() => directory.delete(recursive: true));
    final text = <int>[1, 0xff, 0xfe];
    for (final unit in 'de-DE'.codeUnits) {
      text.addAll([unit, 0]);
    }
    final frame = <int>[
      ...'TLAN'.codeUnits,
      0,
      0,
      0,
      text.length,
      0,
      0,
      ...text,
    ];
    final file = File('${directory.path}/book.mp3');
    await file.writeAsBytes([
      ...'ID3'.codeUnits,
      4,
      0,
      0,
      0,
      0,
      0,
      frame.length,
      ...frame,
    ]);

    expect(await const EmbeddedCoverExtractor().extractLanguage(file), 'de-DE');
  });

  test('extracts chapter titles and positions from an M4B chpl atom', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-chapters-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/book.m4b');
    await file.writeAsBytes(
      _atom('moov', [
        ..._atom('udta', [
          ..._atom('chpl', [
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            2,
            ..._uint64(0),
            ..._chapterTitle('Anfang'),
            ..._uint64(75 * 10000000),
            ..._chapterTitle('Weiter'),
          ]),
        ]),
      ]),
    );

    final chapters = await const EmbeddedCoverExtractor().extractChapters(file);

    expect(chapters, hasLength(2));
    expect(chapters[0].title, 'Anfang');
    expect(chapters[0].position, Duration.zero);
    expect(chapters[1].title, 'Weiter');
    expect(chapters[1].position, const Duration(minutes: 1, seconds: 15));
  });
}

List<int> _atom(String type, List<int> payload) {
  final size = payload.length + 8;
  final bytes = ByteData(4)..setUint32(0, size);
  return [...bytes.buffer.asUint8List(), ...type.codeUnits, ...payload];
}

List<int> _uint64(int value) {
  final bytes = ByteData(8)..setUint64(0, value);
  return bytes.buffer.asUint8List();
}

List<int> _chapterTitle(String value) => [value.length, ...value.codeUnits];
