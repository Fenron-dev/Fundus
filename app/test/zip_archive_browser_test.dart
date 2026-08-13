import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/zip_archive_browser.dart';

void main() {
  test('browses nested ZIP entries and extracts one temporary file', () async {
    final root = await Directory.systemTemp.createTemp('fundus-zip-test-');
    addTearDown(() => root.delete(recursive: true));
    final archivePath = '${root.path}/product.zip';
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('Rules/Book.pdf', [1, 2, 3]))
      ..addFile(ArchiveFile.bytes('Maps/World.png', [4, 5]));
    await File(archivePath).writeAsBytes(ZipEncoder().encode(archive));
    const service = ZipArchiveService();

    final snapshot = await service.inspect(archivePath);
    final rootEntries = snapshot.childrenOf('');
    final rules = rootEntries.singleWhere((entry) => entry.name == 'Rules');
    final book = snapshot.childrenOf(rules.path).single;
    final extracted = await service.extractToTemporaryFile(archivePath, book);

    expect(
      rootEntries.map((entry) => entry.name),
      containsAll(['Maps', 'Rules']),
    );
    expect(book.name, 'Book.pdf');
    expect(await File(extracted).readAsBytes(), [1, 2, 3]);
  });

  test('rejects ZIP slip paths instead of hiding the unsafe entry', () async {
    final root = await Directory.systemTemp.createTemp('fundus-zip-slip-');
    addTearDown(() => root.delete(recursive: true));
    final archivePath = '${root.path}/unsafe.zip';
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('../outside.pdf', [1]));
    await File(archivePath).writeAsBytes(ZipEncoder().encode(archive));

    await expectLater(
      const ZipArchiveService().inspect(archivePath),
      throwsA(
        isA<ZipArchiveException>().having(
          (error) => error.message,
          'message',
          contains('unsicheren Pfad'),
        ),
      ),
    );
  });

  test('rejects archives above the configured entry limit', () async {
    final root = await Directory.systemTemp.createTemp('fundus-zip-limit-');
    addTearDown(() => root.delete(recursive: true));
    final archivePath = '${root.path}/many.zip';
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('one.txt', [1]))
      ..addFile(ArchiveFile.bytes('two.txt', [2]));
    await File(archivePath).writeAsBytes(ZipEncoder().encode(archive));

    await expectLater(
      const ZipArchiveService(maxEntries: 1).inspect(archivePath),
      throwsA(isA<ZipArchiveException>()),
    );
  });
}
