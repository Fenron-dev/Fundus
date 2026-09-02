import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/media_byte_source.dart';

void main() {
  test('memory source reads a bounded range', () async {
    final source = MemoryMediaByteSource(
      'memory:test',
      Uint8List.fromList([0, 1, 2, 3, 4]),
    );

    expect(await source.length(), 5);
    expect(await source.read(start: 1, end: 4), [1, 2, 3]);
  });

  test('ranged source forwards requested byte range', () async {
    int? requestedStart;
    int? requestedEnd;
    final source = RangedMediaByteSource(
      id: 'remote:test',
      contentLength: 10,
      readRange: ({start, end}) async {
        requestedStart = start;
        requestedEnd = end;
        return Uint8List.fromList([9]);
      },
    );

    expect(await source.read(start: 8, end: 9), [9]);
    expect(requestedStart, 8);
    expect(requestedEnd, 9);
  });
}
