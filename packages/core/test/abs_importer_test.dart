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
}
