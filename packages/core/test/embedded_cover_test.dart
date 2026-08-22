import 'dart:convert';
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

  test('extracts WebP artwork from an M4B covr atom', () async {
    final directory = await Directory.systemTemp.createTemp(
      'fundus-webp-cover-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final webp = Uint8List.fromList([
      ...'RIFF'.codeUnits,
      4,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
      ...'VP8 '.codeUnits,
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
                ..._atom('data', [0, 0, 0, 14, 0, 0, 0, 0, ...webp]),
              ]),
            ]),
          ]),
        ]),
      ]),
    );

    final cover = await const EmbeddedCoverExtractor().extract(file);

    expect(cover, isNotNull);
    expect(cover!.extension, 'webp');
    expect(cover.mimeType, 'image/webp');
    expect(cover.bytes, webp);
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

  test('extracts whitelisted identity metadata from M4B atoms', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-metadata-');
    addTearDown(() => directory.delete(recursive: true));
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
              ..._textTag('©nam', 'Der Titel'),
              ..._textTag('©ART', 'Die Autorin'),
              ..._textTag('aART', 'Album-Autorin'),
              ..._textTag('©alb', 'Das Album'),
              ..._freeformTag('SERIES', 'Die Reihe'),
              ..._freeformTag('PART', '2'),
              ..._freeformTag('LANGUAGE', 'German'),
              ..._freeformTag('UNSUPPORTED_FIELD', 'nicht übernehmen'),
            ]),
          ]),
        ]),
      ]),
    );

    final metadata = await const EmbeddedCoverExtractor().extractMetadata(file);

    expect(metadata.title, 'Der Titel');
    expect(metadata.author, 'Die Autorin');
    expect(metadata.albumArtist, 'Album-Autorin');
    expect(metadata.album, 'Das Album');
    expect(metadata.series, 'Die Reihe');
    expect(metadata.part, 2);
    expect(metadata.language, 'German');
  });

  test('extracts whitelisted identity metadata from ID3 frames', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-id3-');
    addTearDown(() => directory.delete(recursive: true));
    final frames = <int>[
      ..._id3TextFrame('TIT2', 'Tracktitel'),
      ..._id3TextFrame('TALB', 'Buchtitel'),
      ..._id3TextFrame('TPE1', 'Autor'),
      ..._id3TextFrame('TPE2', 'Album-Autor'),
      ..._id3UserTextFrame('SERIES', 'Buchreihe'),
      ..._id3UserTextFrame('PART', '3'),
      ..._id3UserTextFrame('IGNORED', 'privat'),
    ];
    final file = File('${directory.path}/book.mp3');
    await file.writeAsBytes([
      ...'ID3'.codeUnits,
      4,
      0,
      0,
      ..._synchsafe(frames.length),
      ...frames,
    ]);

    final metadata = await const EmbeddedCoverExtractor().extractMetadata(file);

    expect(metadata.title, 'Tracktitel');
    expect(metadata.album, 'Buchtitel');
    expect(metadata.author, 'Autor');
    expect(metadata.albumArtist, 'Album-Autor');
    expect(metadata.series, 'Buchreihe');
    expect(metadata.part, 3);
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

List<int> _textTag(String type, String value) => _atom(type, [
  ..._atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]),
]);

List<int> _freeformTag(String name, String value) => _atom('----', [
  ..._atom('mean', [0, 0, 0, 0, ...utf8.encode('com.apple.iTunes')]),
  ..._atom('name', [0, 0, 0, 0, ...utf8.encode(name)]),
  ..._atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(value)]),
]);

List<int> _id3TextFrame(String id, String value) =>
    _id3Frame(id, [3, ...utf8.encode(value)]);

List<int> _id3UserTextFrame(String name, String value) =>
    _id3Frame('TXXX', [3, ...utf8.encode(name), 0, ...utf8.encode(value)]);

List<int> _id3Frame(String id, List<int> payload) => [
  ...id.codeUnits,
  ..._synchsafe(payload.length),
  0,
  0,
  ...payload,
];

List<int> _synchsafe(int value) => [
  (value >> 21) & 0x7f,
  (value >> 14) & 0x7f,
  (value >> 7) & 0x7f,
  value & 0x7f,
];
