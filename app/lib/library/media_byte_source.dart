import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';

/// Common byte-level access for local files, offline copies and remote ranges.
/// Readers can depend on this interface instead of branching on the origin.
abstract interface class FundusMediaByteSource {
  String get id;
  Future<int?> length();
  Future<Uint8List> read({int? start, int? end});
}

/// Bridges the app-level byte source to the core publication contract.
///
/// Readers therefore consume one range-based interface regardless of whether
/// bytes come from a vault file, an offline copy or an HTTP range endpoint.
/// The adapter intentionally does not cache: caching and eviction belong to
/// the source implementation, not to the renderer.
final class PublicationMediaByteSource implements PublicationSource {
  PublicationMediaByteSource(this.source, {required this.kind, String? name})
    : _name = name;

  final FundusMediaByteSource source;
  @override
  final PublicationSourceKind kind;
  final String? _name;

  @override
  String get name => _name ?? source.id;

  @override
  Future<int> length() async {
    final value = await source.length();
    if (value == null || value < 0) {
      throw const PublicationSourceReadException(
        'Die Länge der Publikationsquelle ist nicht verfügbar.',
      );
    }
    return value;
  }

  @override
  Future<Uint8List> read(PublicationByteRange range) async {
    final size = await length();
    if (range.start > size || range.end > size) {
      throw RangeError.range(range.end, range.start, size, 'range');
    }
    final bytes = await source.read(start: range.start, end: range.end);
    if (bytes.length > range.length) {
      throw const PublicationSourceReadException(
        'Die Quelle lieferte mehr Bytes als angefordert.',
      );
    }
    return bytes;
  }
}

final class LocalFileMediaByteSource implements FundusMediaByteSource {
  LocalFileMediaByteSource(this.file);

  final File file;

  @override
  String get id => file.path;

  @override
  Future<int?> length() async => file.length();

  @override
  Future<Uint8List> read({int? start, int? end}) async {
    if (!await file.exists()) {
      throw FileSystemException(
        'Die Mediendatei ist nicht verfügbar.',
        file.path,
      );
    }
    final size = await file.length();
    final first = (start ?? 0).clamp(0, size);
    final last = (end ?? size).clamp(first, size);
    if (first == last) return Uint8List(0);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(first, last)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

final class MemoryMediaByteSource implements FundusMediaByteSource {
  MemoryMediaByteSource(this.id, Uint8List bytes)
    : _bytes = Uint8List.fromList(bytes);

  @override
  final String id;
  final Uint8List _bytes;

  @override
  Future<int?> length() async => _bytes.length;

  @override
  Future<Uint8List> read({int? start, int? end}) async {
    final first = (start ?? 0).clamp(0, _bytes.length);
    final last = (end ?? _bytes.length).clamp(first, _bytes.length);
    return Uint8List.sublistView(_bytes, first, last);
  }
}

typedef FundusMediaRangeReader =
    Future<Uint8List> Function({int? start, int? end});

final class RangedMediaByteSource implements FundusMediaByteSource {
  const RangedMediaByteSource({
    required this.id,
    required this.readRange,
    this.contentLength,
  });

  @override
  final String id;
  final FundusMediaRangeReader readRange;
  final int? contentLength;

  @override
  Future<int?> length() async => contentLength;

  @override
  Future<Uint8List> read({int? start, int? end}) =>
      readRange(start: start, end: end);
}
