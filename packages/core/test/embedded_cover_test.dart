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
  });
}

List<int> _atom(String type, List<int> payload) {
  final size = payload.length + 8;
  final bytes = ByteData(4)..setUint32(0, size);
  return [...bytes.buffer.asUint8List(), ...type.codeUnits, ...payload];
}
