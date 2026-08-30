import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  ScannedFile file(String path, {String? mimeType}) => ScannedFile(
    absolutePath: '/library/$path',
    relativePath: path,
    filename: path.split('/').last,
    extension: path.split('.').last.toLowerCase(),
    size: 10,
    modifiedAt: DateTime.utc(2026),
    mimeType: mimeType,
  );

  test('groups a TTRPG product with PDFs maps and handouts', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );
    final candidates = importer.group([
      file('TTRPG/Dragonlance/Regelwerk.pdf', mimeType: 'application/pdf'),
      file('TTRPG/Dragonlance/Maps/Ansalon.jpg', mimeType: 'image/jpeg'),
      file('TTRPG/Dragonlance/Handouts/Brief.png', mimeType: 'image/png'),
      file('Audiobooks/Autor/Buch/cover.jpg', mimeType: 'image/jpeg'),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'ttrpg_product');
    expect(candidates.single.title, 'Dragonlance');
    expect(candidates.single.directory, 'TTRPG/Dragonlance');
    expect(candidates.single.files, hasLength(3));
  });

  test('creates standalone works for files directly below a media root', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );
    final candidates = importer.group([
      file('Documents/Wichtige Datei.pdf', mimeType: 'application/pdf'),
      file('Pictures/Familie.jpg', mimeType: 'image/jpeg'),
    ]);

    expect(
      candidates.map((item) => item.kind),
      containsAll(['document', 'image']),
    );
    expect(
      candidates.map((item) => item.title),
      containsAll(['Wichtige Datei', 'Familie']),
    );
  });

  test('indexes CBZ files below the document roots', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidates = importer.group([
      file('Documents/Comic 01.cbz', mimeType: 'application/vnd.comicbook+zip'),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'document');
    expect(candidates.single.title, 'Comic 01');
  });

  test('groups CBZ chapters and cover below a manga root', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidates = importer.group([
      file('Manga/Rebirth/cover.png', mimeType: 'image/png'),
      file(
        'Manga/Rebirth/Rebirth - Kapitel 0280.cbz',
        mimeType: 'application/vnd.comicbook+zip',
      ),
      file(
        'Manga/Rebirth/Rebirth - Kapitel 0281.cbz',
        mimeType: 'application/vnd.comicbook+zip',
      ),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'manga');
    expect(candidates.single.title, 'Rebirth');
    expect(candidates.single.directory, 'Manga/Rebirth');
    expect(candidates.single.files, hasLength(3));
    expect(candidates.single.coverFile?.filename, 'cover.png');
  });

  test('recognizes WebP cover files for publication works', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidate = importer.group([
      file('Webnovels/Story/cover.webp', mimeType: 'image/webp'),
      file('Webnovels/Story/Story.epub', mimeType: 'application/epub+zip'),
    ]).single;

    expect(candidate.coverFile?.filename, 'cover.webp');
  });

  test('keeps webnovels separate from books and documents', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidates = importer.group([
      file('Webnovels/Arc One/chapter-1.html', mimeType: 'text/html'),
      file('Books/Novel.epub', mimeType: 'application/epub+zip'),
      file('Documents/Notes.pdf', mimeType: 'application/pdf'),
    ]);

    expect(candidates.map((candidate) => candidate.kind), [
      'document',
      'ebook',
      'webnovel',
    ]);
  });

  test('sorts webnovel chapters by natural chapter number', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidate = importer.group([
      file('Webnovels/Story/chapter-10.html', mimeType: 'text/html'),
      file('Webnovels/Story/chapter-2.html', mimeType: 'text/html'),
      file('Webnovels/Story/chapter-1.html', mimeType: 'text/html'),
    ]).single;

    expect(candidate.files.map((file) => file.filename), [
      'chapter-1.html',
      'chapter-2.html',
      'chapter-10.html',
    ]);
  });

  test('groups movie files into a portable film work', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidate = importer.group([
      file('Movies/Star Wars/cover.webp', mimeType: 'image/webp'),
      file('Movies/Star Wars/Star Wars.mkv', mimeType: 'video/x-matroska'),
    ]).single;

    expect(candidate.kind, 'movie');
    expect(candidate.title, 'Star Wars');
    expect(candidate.directory, 'Movies/Star Wars');
    expect(candidate.coverFile?.filename, 'cover.webp');
  });

  test('groups a TV series and its season files into one work', () {
    final importer = DocumentImporter(
      mediaRoots: LibraryConfiguration.defaults,
    );

    final candidate = importer.group([
      file(
        'TV Shows/Firefly/Season 01/Firefly - S01E02.mp4',
        mimeType: 'video/mp4',
      ),
      file(
        'TV Shows/Firefly/Season 01/Firefly - S01E01.mp4',
        mimeType: 'video/mp4',
      ),
    ]).single;

    expect(candidate.kind, 'tv');
    expect(candidate.title, 'Firefly');
    expect(candidate.directory, 'TV Shows/Firefly');
    expect(candidate.files.map((item) => item.filename), [
      'Firefly - S01E01.mp4',
      'Firefly - S01E02.mp4',
    ]);
  });
}
