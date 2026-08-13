import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef FundusRemoteContentOpener =
    Future<FundusRemoteDocumentSource> Function();

final class FundusRemoteDocumentSource {
  const FundusRemoteDocumentSource({
    required this.bytes,
    required this.close,
    this.contentLength,
  });

  final Stream<List<int>> bytes;
  final int? contentLength;
  final void Function() close;
}

final class FundusRemoteDocumentCache {
  FundusRemoteDocumentCache({
    Directory? root,
    this.maximumBytes = 256 * 1024 * 1024,
    this.maximumAge = const Duration(hours: 24),
  }) : _configuredRoot = root;

  final Directory? _configuredRoot;
  final int maximumBytes;
  final Duration maximumAge;

  Future<File> obtain({
    required String cacheKey,
    required String filename,
    required FundusRemoteContentOpener open,
  }) async {
    final root = await _root();
    await root.create(recursive: true);
    await removeExpired(root);
    final extension = _safeExtension(filename);
    final digest = sha256.convert(utf8.encode(cacheKey)).toString();
    final destination = File(p.join(root.path, '$digest$extension'));
    if (await destination.exists() && await destination.length() > 0) {
      return destination;
    }
    final partial = File('${destination.path}.part');
    if (await partial.exists()) await partial.delete();
    final remote = await open();
    IOSink? sink;
    try {
      final announced = remote.contentLength;
      if (announced != null && announced > maximumBytes) {
        throw const FundusRemoteDocumentException(
          'Die Datei ist für eine temporäre Vorschau zu groß.',
        );
      }
      sink = partial.openWrite();
      var received = 0;
      await sink.addStream(
        remote.bytes.timeout(const Duration(seconds: 30)).map((chunk) {
          received += chunk.length;
          if (received > maximumBytes) {
            throw const FundusRemoteDocumentException(
              'Die Datei ist für eine temporäre Vorschau zu groß.',
            );
          }
          return chunk;
        }),
      );
      await sink.close();
      sink = null;
      if (await destination.exists()) await destination.delete();
      return await partial.rename(destination.path);
    } finally {
      await sink?.close();
      remote.close();
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> removeExpired([Directory? directory]) async {
    final root = directory ?? await _root();
    if (!await root.exists()) return;
    final cutoff = DateTime.now().subtract(maximumAge);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        final modified = await entity.lastModified();
        if (modified.isBefore(cutoff) || entity.path.endsWith('.part')) {
          await entity.delete();
        }
      } on FileSystemException {
        // A concurrently removed cache entry needs no further handling.
      }
    }
  }

  Future<Directory> _root() async =>
      _configuredRoot ??
      Directory(
        p.join((await getTemporaryDirectory()).path, 'fundus-remote-documents'),
      );

  static String _safeExtension(String filename) {
    final extension = p.extension(filename).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(extension) ? extension : '';
  }
}

final class FundusRemoteDocumentException implements Exception {
  const FundusRemoteDocumentException(this.message);

  final String message;

  @override
  String toString() => message;
}
