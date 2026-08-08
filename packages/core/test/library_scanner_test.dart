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
    await File(p.join(book.path, '01 - Anfang.mp3')).writeAsBytes([1, 2, 3]);
    await File(p.join(book.path, 'cover.jpg')).writeAsBytes([4, 5]);
    final internal = Directory(p.join(root.path, '.library'));
    await internal.create();
    await File(p.join(internal.path, 'index.db')).writeAsBytes([6]);

    final events = await LibraryScanner().scan(root).toList();
    final files = events
        .map((event) => event.file)
        .whereType<ScannedFile>()
        .toList();

    expect(files, hasLength(2));
    expect(
      files.map((file) => file.relativePath),
      contains('Autor/Serie/01 - Titel/01 - Anfang.mp3'),
    );
    expect(files.map((file) => file.mimeType), contains('audio/mpeg'));
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
