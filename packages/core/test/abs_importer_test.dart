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
}
