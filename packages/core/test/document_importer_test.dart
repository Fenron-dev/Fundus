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
}
