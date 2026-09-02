import 'dart:io';
import 'dart:typed_data';

/// Common byte-level access for local files, offline copies and remote ranges.
/// Readers can depend on this interface instead of branching on the origin.
abstract interface class FundusMediaByteSource {
  String get id;
  Future<int?> length();
  Future<Uint8List> read({int? start, int? end});
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
    final bytes = await file.readAsBytes();
    final first = (start ?? 0).clamp(0, bytes.length);
    final last = (end ?? bytes.length).clamp(first, bytes.length);
    return Uint8List.sublistView(bytes, first, last);
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
