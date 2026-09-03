import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('video variants are recognized by every client', () {
    for (final kind in const [
      'movie',
      'tv',
      'video',
      'anime_movie',
      'anime_tv',
      'hhh_movie',
      'hhh_tv',
    ]) {
      expect(VideoWorkKind.isVideo(kind), isTrue, reason: kind);
    }
    expect(VideoWorkKind.isVideo('manga'), isFalse);
  });

  test('variants share the correct preference family', () {
    expect(VideoWorkKind.base('anime_movie'), 'movie');
    expect(VideoWorkKind.base('hhh_tv'), 'tv');
    expect(VideoWorkKind.base('video'), 'video');
    expect(VideoWorkKind.base('manga'), 'manga');
  });
}
