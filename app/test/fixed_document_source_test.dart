import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/fixed_document_source.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('file source preserves display name and provenance', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-fixed-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/map.pdf');
    await file.writeAsBytes([1, 2, 3]);

    final source = FileFixedDocumentSource(
      file.path,
      kind: PublicationSourceKind.offline,
    );

    expect(source.name, 'map.pdf');
    expect(source.kind, PublicationSourceKind.offline);
    expect(await source.materialize(), file.path);
  });

  test('virtual source materializes only once', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-fixed-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/cached-document');
    await file.writeAsBytes([1, 2, 3]);
    var calls = 0;
    final source = MaterializedFixedDocumentSource(
      name: 'remote.pdf',
      kind: PublicationSourceKind.remote,
      materialize: () async {
        calls++;
        return file.path;
      },
    );

    expect(await source.materialize(), file.path);
    expect(await source.materialize(), file.path);
    expect(source.name, 'remote.pdf');
    expect(source.kind, PublicationSourceKind.remote);
    expect(calls, 1);
  });

  test('virtual source rejects a missing materialized file', () async {
    final source = MaterializedFixedDocumentSource(
      name: 'missing.pdf',
      kind: PublicationSourceKind.remote,
      materialize: () async => '/definitely/not/a/fundus-document.pdf',
    );

    await expectLater(
      source.materialize(),
      throwsA(isA<FixedDocumentSourceException>()),
    );
  });
}
