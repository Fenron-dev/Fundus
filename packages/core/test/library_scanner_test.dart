import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('scanner streams portable paths and ignores Fundus internals', () async {
    final root = await Directory.systemTemp.createTemp('fundus-scanner-');
    addTearDown(() => root.delete(recursive: true));

    final book = Directory(p.join(root.path, 'Autor', 'Serie', '01 - Titel'));
    await book.create(recursive: true);
    await File(
      p.join(book.path, '01 - Anfang.mp3'),
    ).writeAsBytes([0xff, 0xfb, 0x90, 0x64, ...List.filled(16, 0)]);
    await File(p.join(book.path, 'cover.jpg')).writeAsBytes([4, 5]);
    await File(p.join(book.path, '._01 - Anfang.mp3')).writeAsBytes([0, 0, 0]);
    await File(p.join(book.path, '._cover.jpg')).writeAsBytes([0, 0, 0]);
    final internal = Directory(p.join(root.path, '.library'));
    await internal.create();
    await File(p.join(internal.path, 'index.db')).writeAsBytes([6]);
    final synologyMetadata = Directory(
      p.join(book.path, '@eaDir', 'cover.jpg'),
    );
    await synologyMetadata.create(recursive: true);
    await File(
      p.join(synologyMetadata.path, 'SYNOPHOTO_THUMB_XL.jpg'),
    ).writeAsBytes([7]);
    final appleMetadata = Directory(p.join(root.path, '.AppleDouble'));
    await appleMetadata.create();
    await File(p.join(appleMetadata.path, 'metadata')).writeAsBytes([8]);

    final events = await LibraryScanner().scan(root).toList();
    final files = events
        .map((event) => event.file)
        .whereType<ScannedFile>()
        .toList();

    expect(files, hasLength(2));
    expect(files.map((file) => file.filename), isNot(contains('._cover.jpg')));
    expect(
      files.map((file) => file.relativePath),
      contains('Autor/Serie/01 - Titel/01 - Anfang.mp3'),
    );
    expect(files.map((file) => file.mimeType), contains('audio/mpeg'));
    final audio = files.singleWhere((file) => file.extension == 'mp3');
    expect(audio.audioMetadata?.codec, 'MP3');
    expect(audio.audioMetadata?.sampleRateHz, 44100);
    expect(events.last.kind, ScanEventKind.completed);
  });

  test('scanner can be cancelled before traversing files', () async {
    final root = await Directory.systemTemp.createTemp('fundus-cancel-');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'track.mp3')).writeAsBytes([1]);
    final token = ScanCancellationToken()..cancel();

    final events = await LibraryScanner()
        .scan(root, cancellationToken: token)
        .toList();

    expect(events.last.kind, ScanEventKind.cancelled);
  });
}
