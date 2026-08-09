import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reads whitelisted ABS metadata and converts HTML to plain text',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'fundus-abs-meta-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/metadata.json');
      await file.writeAsString(
        jsonEncode({
          'title': 'Der Beispielband',
          'subtitle': 'Chroniken der Testwelt',
          'authors': ['Beispielautor'],
          'narrators': ['Sprecher Eins'],
          'series': ['Chroniken der Testwelt #1'],
          'genres': ['Fantasy'],
          'tags': ['Abenteuer'],
          'publishedYear': 2024,
          'publisher': 'Beispielverlag',
          'description':
              '<p>Eine <strong>große</strong> Reise &amp; Gefahr.</p><p>Zweiter Absatz.</p>',
          'language': 'de',
          'isbn': '1234567890',
          'asin': 'ABC123',
          'explicit': false,
          'abridged': false,
          'unknownPrivateField': 'must not be imported',
        }),
      );

      final metadata = await const AbsMetadataReader().read(file);

      expect(metadata, isNotNull);
      expect(metadata!.title, 'Der Beispielband');
      expect(metadata.author, 'Beispielautor');
      expect(metadata.series, 'Chroniken der Testwelt');
      expect(metadata.sequence, 1);
      expect(
        metadata.description,
        'Eine große Reise & Gefahr.\n\nZweiter Absatz.',
      );
      expect(
        metadata.toDatabaseMetadata(),
        isNot(contains('unknownPrivateField')),
      );
    },
  );
}
