import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('newer compatible format opens read-only', () {
    const manifest = LibraryManifest(
      libraryId: 'library-id',
      formatVersion: 2,
      minReaderVersion: 1,
      createdBy: 'Fundus test',
    );

    expect(
      manifest.compatibility(supportedFormatVersion: 1).mode,
      LibraryOpenMode.readOnly,
    );
  });

  test('newer minimum reader is rejected', () {
    const manifest = LibraryManifest(
      libraryId: 'library-id',
      formatVersion: 2,
      minReaderVersion: 3,
      createdBy: 'Fundus test',
    );

    expect(
      manifest.compatibility(readerVersion: 1).mode,
      LibraryOpenMode.incompatible,
    );
  });
}
