import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  final importer = AbsImporter();

  test('parses author series decimal sequence and German title', () {
    final identity = importer.parseBookDirectory(
      'Sanderson, Brandon/Mistborn/2,5 - Das elfte Metall',
    );

    expect(identity, isNotNull);
    expect(identity!.author, 'Sanderson, Brandon');
    expect(identity.series, 'Mistborn');
    expect(identity.sequence, 2.5);
    expect(identity.title, 'Das elfte Metall');
  });

  test('parses a book without series', () {
    final identity = importer.parseBookDirectory('Franz Kafka/Die Verwandlung');

    expect(identity!.series, isNull);
    expect(identity.title, 'Die Verwandlung');
  });

  test('strips a standard media root before parsing the identity', () {
    final identity = importer.parseBookDirectory(
      'Audiobooks/Aaron Oster/Master of Monster Arts/01 - Foundation',
    );

    expect(identity, isNotNull);
    expect(identity!.author, 'Aaron Oster');
    expect(identity.series, 'Master of Monster Arts');
    expect(identity.sequence, 1);
    expect(identity.title, 'Foundation');
  });

  test('supports case-insensitive and nested configured media roots', () {
    final configured = AbsImporter(
      mediaRootNames: const ['Medien/Meine Hörbücher'],
    );
    final identity = configured.parseBookDirectory(
      'medien/meine hörbücher/Autor/Serie/02 - Titel',
    );

    expect(identity, isNotNull);
    expect(identity!.author, 'Autor');
    expect(identity.series, 'Serie');
    expect(identity.sequence, 2);
    expect(identity.title, 'Titel');
  });

  test('imports a loose audiobook directly from the library root', () {
    final candidates = importer.group([_audioFile('Ein loses Hörbuch.m4b')]);

    expect(candidates, hasLength(1));
    expect(candidates.single.identity.author, 'Unbekannt');
    expect(candidates.single.identity.title, 'Ein loses Hörbuch');
    expect(candidates.single.directory, '.');
  });

  test('imports an audiobook below a media root without ABS hierarchy', () {
    final candidates = importer.group([
      _audioFile('Audiobooks/Mein Hörbuch/01 - Anfang.mp3'),
      _audioFile('Audiobooks/Mein Hörbuch/02 - Ende.mp3'),
    ]);

    expect(candidates, hasLength(1));
    expect(candidates.single.identity.author, 'Unbekannt');
    expect(candidates.single.identity.title, 'Mein Hörbuch');
    expect(candidates.single.audioFiles, hasLength(2));
  });
}

ScannedFile _audioFile(String path) => ScannedFile(
  absolutePath: '/library/$path',
  relativePath: path,
  filename: path.split('/').last,
  extension: path.split('.').last.toLowerCase(),
  size: 1,
  modifiedAt: DateTime(2026),
  mimeType: 'audio/mp4',
);
