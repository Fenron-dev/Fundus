import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('memory source reads deterministic half-open byte ranges', () async {
    final source = MemoryPublicationSource(
      Uint8List.fromList([10, 20, 30, 40]),
      name: 'memory.epub',
    );

    expect(await source.length(), 4);
    expect(await source.read(const PublicationByteRange(1, 3)), [20, 30]);
    expect(await source.readAll(), [10, 20, 30, 40]);
  });

  test('file source marks offline origin and reads a byte range', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-source-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}book.epub');
    await file.writeAsBytes([1, 2, 3, 4, 5]);
    final source = FilePublicationSource(
      file.path,
      kind: PublicationSourceKind.offline,
    );

    expect(source.name, 'book.epub');
    expect(source.kind, PublicationSourceKind.offline);
    expect(await source.read(const PublicationByteRange(2, 5)), [3, 4, 5]);
  });

  test('readAll rejects oversized sources before requesting bytes', () async {
    var rangeRead = false;
    final source = CallbackPublicationSource(
      name: 'remote.epub',
      kind: PublicationSourceKind.remote,
      lengthReader: () async => 100,
      rangeReader: (range) async {
        rangeRead = true;
        return Uint8List(range.length);
      },
    );

    await expectLater(
      source.readAll(maxBytes: 50),
      throwsA(isA<PublicationSourceTooLargeException>()),
    );
    expect(rangeRead, isFalse);
  });

  test('callback source rejects incomplete full reads', () async {
    final source = CallbackPublicationSource(
      name: 'remote.epub',
      kind: PublicationSourceKind.remote,
      lengthReader: () async => 4,
      rangeReader: (_) async => Uint8List.fromList([1, 2]),
    );

    await expectLater(
      source.readAll(),
      throwsA(isA<PublicationSourceReadException>()),
    );
  });
}
