import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/server/fundus_remote_stream_proxy.dart';

void main() {
  test('detects WebP covers served through the local media proxy', () {
    final contentType = remoteCoverContentType([
      0x52,
      0x49,
      0x46,
      0x46,
      0x04,
      0x00,
      0x00,
      0x00,
      0x57,
      0x45,
      0x42,
      0x50,
    ]);

    expect(contentType.mimeType, 'image/webp');
  });

  test('falls back to binary content for unknown cover bytes', () {
    expect(remoteCoverContentType([1, 2, 3]), ContentType.binary);
  });
}
