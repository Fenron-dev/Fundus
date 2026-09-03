import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Persistent, bounded cache for remote artwork.
///
/// Covers are immutable from the client's perspective and are safe to keep
/// outside the vault. A partial download is never exposed as a valid cover.
final class FundusRemoteCoverCache {
  FundusRemoteCoverCache({Directory? root, this.maximumBytes = 8 * 1024 * 1024})
    : _configuredRoot = root;

  final Directory? _configuredRoot;
  final int maximumBytes;

  Future<File?> load(String cacheKey) async {
    final file = await _file(cacheKey);
    if (!await file.exists()) return null;
    try {
      if (await file.length() <= 0 || await file.length() > maximumBytes) {
        await file.delete();
        return null;
      }
      return file;
    } on FileSystemException {
      return null;
    }
  }

  Future<File?> obtain({
    required String cacheKey,
    required Future<Uint8List> Function() open,
  }) async {
    final cached = await load(cacheKey);
    if (cached != null) return cached;

    final destination = await _file(cacheKey);
    await destination.parent.create(recursive: true);
    final partial = File('${destination.path}.part');
    try {
      if (await partial.exists()) await partial.delete();
      final bytes = await open();
      if (bytes.isEmpty || bytes.length > maximumBytes) return null;
      await partial.writeAsBytes(bytes, flush: true);
      if (await destination.exists()) await destination.delete();
      return await partial.rename(destination.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<File> _file(String cacheKey) async {
    final root =
        _configuredRoot ??
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'fundus-remote-covers',
          ),
        );
    final digest = sha256.convert(utf8.encode(cacheKey)).toString();
    return File(p.join(root.path, '$digest.cover'));
  }
}
