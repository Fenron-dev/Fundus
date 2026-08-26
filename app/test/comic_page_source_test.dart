import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/comic_page_source.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test(
    'archive source exposes naturally sorted pages and provenance',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-comic-source-',
      );
      addTearDown(() => root.delete(recursive: true));
      final archivePath = '${root.path}/chapter.cbz';
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('pages/10.jpg', [10]))
        ..addFile(ArchiveFile.bytes('pages/2.webp', [2]))
        ..addFile(ArchiveFile.bytes('ComicInfo.xml', [1]));
      await File(archivePath).writeAsBytes(ZipEncoder().encode(archive));
      final source = ArchiveComicPageSource(
        archivePath,
        kind: PublicationSourceKind.offline,
        name: 'Kapitel 7.cbz',
      );

      final pages = await source.pages();

      expect(source.name, 'Kapitel 7.cbz');
      expect(source.kind, PublicationSourceKind.offline);
      expect(pages.map((page) => page.id), ['pages/2.webp', 'pages/10.jpg']);
    },
  );

  test(
    'archive source materializes selected pages through one contract',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-comic-pages-');
      addTearDown(() => root.delete(recursive: true));
      final archivePath = '${root.path}/chapter.cbz';
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('001.png', [1, 2]))
        ..addFile(ArchiveFile.bytes('002.png', [3, 4]));
      await File(archivePath).writeAsBytes(ZipEncoder().encode(archive));
      final source = ArchiveComicPageSource(archivePath);
      final pages = await source.pages();

      final materialized = await source.materialize([pages.last]);

      expect(await File(materialized['002.png']!).readAsBytes(), [3, 4]);
      expect(materialized, hasLength(1));
    },
  );
}
