import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

abstract interface class FixedDocumentSource {
  String get name;

  PublicationSourceKind get kind;

  Future<String> materialize();

  Future<void> dispose();
}

final class FixedDocumentSourceException implements Exception {
  const FixedDocumentSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class FileFixedDocumentSource implements FixedDocumentSource {
  FileFixedDocumentSource(
    this.path, {
    String? name,
    this.kind = PublicationSourceKind.local,
  }) : name = name ?? p.basename(path);

  final String path;

  @override
  final String name;

  @override
  final PublicationSourceKind kind;

  @override
  Future<String> materialize() async {
    if (!await File(path).exists()) {
      throw const FixedDocumentSourceException(
        'Die Datei ist nicht mehr am gespeicherten Ort vorhanden.',
      );
    }
    return path;
  }

  @override
  Future<void> dispose() async {}
}

typedef FixedDocumentMaterializer = Future<String> Function();
typedef FixedDocumentRelease = Future<void> Function(String path);

/// Adapts a remote or otherwise virtual document to renderers that still need
/// a local file handle. Transport and cache policy remain outside the viewer.
final class MaterializedFixedDocumentSource implements FixedDocumentSource {
  MaterializedFixedDocumentSource({
    required this.name,
    required this.kind,
    required FixedDocumentMaterializer materialize,
    FixedDocumentRelease? release,
  }) : _materializer = materialize,
       _release = release;

  @override
  final String name;

  @override
  final PublicationSourceKind kind;

  final FixedDocumentMaterializer _materializer;
  final FixedDocumentRelease? _release;
  Future<String>? _materializedPath;

  @override
  Future<String> materialize() => _materializedPath ??= _materialize();

  Future<String> _materialize() async {
    final path = await _materializer();
    if (path.trim().isEmpty || !await File(path).exists()) {
      throw const FixedDocumentSourceException(
        'Das Dokument konnte nicht lokal bereitgestellt werden.',
      );
    }
    return path;
  }

  @override
  Future<void> dispose() async {
    final release = _release;
    final materialized = _materializedPath;
    if (release == null || materialized == null) return;
    final path = await materialized;
    await release(path);
  }
}
