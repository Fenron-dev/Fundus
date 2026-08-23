import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reads metadata and nested navigation from a safe EPUB package',
    () async {
      final publication = await const EpubPackageAdapter().openBytes(
        _epubFixture(),
        sourceName: 'fallback.epub',
      );

      expect(publication.title, 'Die Testnovel');
      expect(publication.authors, ['Erika Beispiel']);
      expect(publication.languages, ['de']);
      expect(publication.subjects, ['Fantasy']);
      expect(publication.publishers, ['Fundus Testverlag']);
      expect(publication.description, 'Eine sichere Testbeschreibung.');
      expect(publication.chapters, hasLength(2));
      expect(publication.chapters.first.title, 'Kapitel Eins');
      expect(publication.chapters.first.depth, 0);
      expect(publication.chapters.last.title, 'Unterkapitel Zwei');
      expect(publication.chapters.last.depth, 1);
      expect(publication.chapters.last.html, contains('Zweiter Absatz'));
    },
  );

  test('opens the same EPUB through the common publication source', () async {
    final publication = await const EpubPackageAdapter().openSource(
      MemoryPublicationSource(_epubFixture(), name: 'source.epub'),
    );

    expect(publication.title, 'Die Testnovel');
    expect(publication.chapters, hasLength(2));
  });

  test('rejects an EPUB entry that can escape the package root', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('META-INF/container.xml', '<container/>'))
      ..addFile(ArchiveFile.string('../outside.xhtml', '<p>unsafe</p>'));

    await expectLater(
      const EpubPackageAdapter().openBytes(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      ),
      throwsA(
        isA<EpubPackageException>().having(
          (error) => error.message,
          'message',
          contains('unsicheren Pfad'),
        ),
      ),
    );
  });

  test('enforces entry limits before parsing package content', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('META-INF/container.xml', '<container/>'))
      ..addFile(ArchiveFile.string('one.xhtml', '<p>one</p>'));

    await expectLater(
      const EpubPackageAdapter(
        limits: EpubPackageLimits(maxEntries: 1),
      ).openBytes(Uint8List.fromList(ZipEncoder().encode(archive))),
      throwsA(
        isA<EpubPackageException>().having(
          (error) => error.message,
          'message',
          contains('zu viele Einträge'),
        ),
      ),
    );
  });
}

Uint8List _epubFixture() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/content.opf',
        '''<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">urn:uuid:fundus-test</dc:identifier>
    <dc:title>Die Testnovel</dc:title>
    <dc:creator>Erika Beispiel</dc:creator>
    <dc:language>de</dc:language>
    <dc:subject>Fantasy</dc:subject>
    <dc:publisher>Fundus Testverlag</dc:publisher>
    <dc:description>Eine sichere Testbeschreibung.</dc:description>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="chapter-1" href="Text/chapter-1.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter-2" href="Text/chapter-2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="chapter-1"/>
    <itemref idref="chapter-2"/>
  </spine>
</package>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/toc.ncx',
        '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:fundus-test"/></head>
  <docTitle><text>Die Testnovel</text></docTitle>
  <navMap>
    <navPoint id="chapter-1" playOrder="1">
      <navLabel><text>Kapitel Eins</text></navLabel>
      <content src="Text/chapter-1.xhtml"/>
      <navPoint id="chapter-2" playOrder="2">
        <navLabel><text>Unterkapitel Zwei</text></navLabel>
        <content src="Text/chapter-2.xhtml"/>
      </navPoint>
    </navPoint>
  </navMap>
</ncx>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/Text/chapter-1.xhtml',
        '<html><head><title>Eins</title></head><body><p>Erster Absatz.</p></body></html>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/Text/chapter-2.xhtml',
        '<html><head><title>Zwei</title></head><body><p>Zweiter Absatz.</p></body></html>',
      ),
    );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
