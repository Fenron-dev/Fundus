import 'dart:io';
import 'dart:typed_data';

/// Origin of publication bytes. Reader and package adapters must not need to
/// know whether a work is local, downloaded for offline use, or remote.
enum PublicationSourceKind { local, offline, remote, memory }

/// A half-open byte range (`start` inclusive, `end` exclusive).
final class PublicationByteRange {
  const PublicationByteRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  final int start;
  final int end;

  int get length => end - start;
}

abstract interface class PublicationSource {
  String get name;

  PublicationSourceKind get kind;

  Future<int> length();

  /// Reads exactly the requested half-open range unless it reaches EOF.
  Future<Uint8List> read(PublicationByteRange range);
}

extension PublicationSourceReadAll on PublicationSource {
  Future<Uint8List> readAll({int? maxBytes}) async {
    final byteLength = await length();
    if (byteLength < 0) {
      throw const FormatException('Ungültige Länge der Publikationsquelle.');
    }
    if (maxBytes != null && byteLength > maxBytes) {
      throw PublicationSourceTooLargeException(byteLength, maxBytes);
    }
    final bytes = await read(PublicationByteRange(0, byteLength));
    if (bytes.length != byteLength) {
      throw PublicationSourceReadException(
        'Die Publikationsquelle wurde unvollständig gelesen '
        '(${bytes.length} von $byteLength Bytes).',
      );
    }
    return bytes;
  }
}

final class FilePublicationSource implements PublicationSource {
  const FilePublicationSource(
    this.path, {
    this.kind = PublicationSourceKind.local,
    String? name,
  }) : _name = name;

  final String path;
  @override
  final PublicationSourceKind kind;
  final String? _name;

  @override
  String get name => _name ?? path.split(Platform.pathSeparator).last;

  @override
  Future<int> length() => File(path).length();

  @override
  Future<Uint8List> read(PublicationByteRange range) async {
    final file = File(path);
    if (!await file.exists()) {
      throw PublicationSourceReadException(
        'Die Publikationsdatei ist nicht mehr vorhanden.',
      );
    }
    final size = await file.length();
    _validateRange(range, size);
    if (range.length == 0) return Uint8List(0);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(range.start, range.end)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}

final class MemoryPublicationSource implements PublicationSource {
  MemoryPublicationSource(
    Uint8List bytes, {
    required this.name,
    this.kind = PublicationSourceKind.memory,
  }) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  @override
  final String name;
  @override
  final PublicationSourceKind kind;

  @override
  Future<int> length() async => _bytes.length;

  @override
  Future<Uint8List> read(PublicationByteRange range) async {
    _validateRange(range, _bytes.length);
    return Uint8List.fromList(_bytes.sublist(range.start, range.end));
  }
}

typedef PublicationLengthReader = Future<int> Function();
typedef PublicationRangeReader =
    Future<Uint8List> Function(PublicationByteRange range);

/// Adapter for HTTP range endpoints and other non-file sources.
final class CallbackPublicationSource implements PublicationSource {
  const CallbackPublicationSource({
    required this.name,
    required this.kind,
    required PublicationLengthReader lengthReader,
    required PublicationRangeReader rangeReader,
  }) : _lengthReader = lengthReader,
       _rangeReader = rangeReader;

  @override
  final String name;
  @override
  final PublicationSourceKind kind;
  final PublicationLengthReader _lengthReader;
  final PublicationRangeReader _rangeReader;

  @override
  Future<int> length() => _lengthReader();

  @override
  Future<Uint8List> read(PublicationByteRange range) async {
    final size = await length();
    _validateRange(range, size);
    final bytes = await _rangeReader(range);
    if (bytes.length > range.length) {
      throw PublicationSourceReadException(
        'Die Quelle lieferte mehr Bytes als angefordert.',
      );
    }
    return bytes;
  }
}

final class PublicationSourceTooLargeException implements Exception {
  const PublicationSourceTooLargeException(this.actualBytes, this.maximumBytes);

  final int actualBytes;
  final int maximumBytes;

  @override
  String toString() =>
      'PublicationSourceTooLargeException($actualBytes > $maximumBytes)';
}

final class PublicationSourceReadException implements Exception {
  const PublicationSourceReadException(this.message);

  final String message;

  @override
  String toString() => 'PublicationSourceReadException: $message';
}

void _validateRange(PublicationByteRange range, int size) {
  if (size < 0 || range.start > size || range.end > size) {
    throw RangeError.range(range.end, range.start, size, 'range');
  }
}
