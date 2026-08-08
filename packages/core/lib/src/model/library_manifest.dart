import 'dart:convert';
import 'dart:io';

enum LibraryOpenMode { readWrite, readOnly, incompatible }

final class LibraryCompatibility {
  const LibraryCompatibility(this.mode, this.message);

  final LibraryOpenMode mode;
  final String message;
}

final class LibraryManifest {
  const LibraryManifest({
    required this.libraryId,
    required this.formatVersion,
    required this.minReaderVersion,
    required this.createdBy,
  });

  static const currentFormatVersion = 1;
  static const currentReaderVersion = 1;

  final String libraryId;
  final int formatVersion;
  final int minReaderVersion;
  final String createdBy;

  factory LibraryManifest.fromJson(Map<String, Object?> json) {
    return LibraryManifest(
      libraryId: json['library_id']! as String,
      formatVersion: json['format_version']! as int,
      minReaderVersion: json['min_reader_version']! as int,
      createdBy: json['created_by']! as String,
    );
  }

  Map<String, Object?> toJson() => {
    'library_id': libraryId,
    'format_version': formatVersion,
    'min_reader_version': minReaderVersion,
    'created_by': createdBy,
  };

  LibraryCompatibility compatibility({
    int readerVersion = currentReaderVersion,
    int supportedFormatVersion = currentFormatVersion,
  }) {
    if (minReaderVersion > readerVersion) {
      return LibraryCompatibility(
        LibraryOpenMode.incompatible,
        'Diese Bibliothek benötigt Reader-Version $minReaderVersion.',
      );
    }
    if (formatVersion > supportedFormatVersion) {
      return const LibraryCompatibility(
        LibraryOpenMode.readOnly,
        'Neuere Bibliotheksversion: eingeschränkter Lesemodus.',
      );
    }
    return const LibraryCompatibility(
      LibraryOpenMode.readWrite,
      'Bibliothek kann gelesen und geändert werden.',
    );
  }

  static Future<LibraryManifest> read(File file) async {
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    return LibraryManifest.fromJson(json);
  }

  Future<void> write(File file) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}
