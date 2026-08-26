import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import '../library/comic_page_source.dart';
import 'fundus_remote_client.dart';

typedef RemoteComicManifestLoader =
    Future<FundusRemoteComicManifest> Function();
typedef RemoteComicPageLoader = Future<Uint8List> Function(int pageIndex);

/// HTTP-backed source that keeps the archive on the server and only
/// materializes pages requested by the reader/preloader.
final class HttpComicPageSource implements ComicPageSource {
  HttpComicPageSource({
    required this.name,
    required RemoteComicManifestLoader loadManifest,
    required RemoteComicPageLoader loadPage,
  }) : _loadManifest = loadManifest,
       _loadPage = loadPage;

  @override
  final String name;
  @override
  PublicationSourceKind get kind => PublicationSourceKind.remote;

  final RemoteComicManifestLoader _loadManifest;
  final RemoteComicPageLoader _loadPage;
  final Map<String, FundusRemoteComicPage> _remotePages = {};
  final Map<String, Future<String>> _materialized = {};
  Directory? _cacheDirectory;

  @override
  Future<List<ComicPage>> pages() async {
    final manifest = await _loadManifest();
    _remotePages
      ..clear()
      ..addEntries(manifest.pages.map((page) => MapEntry(page.id, page)));
    return [
      for (final page in manifest.pages)
        ComicPage(
          id: page.id,
          name: page.name,
          size: page.size,
          mimeType: page.mimeType,
          width: page.width,
          height: page.height,
        ),
    ];
  }

  @override
  Future<Map<String, String>> materialize(List<ComicPage> pages) async {
    if (pages.isEmpty) return const {};
    if (pages.any((page) => !_remotePages.containsKey(page.id))) {
      await this.pages();
    }
    final result = <String, String>{};
    await Future.wait([
      for (final page in pages)
        () async {
          final remote = _remotePages[page.id];
          if (remote == null ||
              remote.name != page.name ||
              remote.size != page.size) {
            throw const HttpException(
              'Die Comicseite ist nicht mehr Teil der Remote-Quelle.',
            );
          }
          result[page.id] = await _materialized.putIfAbsent(
            page.id,
            () => _writePage(remote),
          );
        }(),
    ]);
    return result;
  }

  Future<String> _writePage(FundusRemoteComicPage page) async {
    final root = _cacheDirectory ??= await _createCacheDirectory();
    final extension = p.extension(page.name).toLowerCase();
    final target = File(p.join(root.path, '${page.index}$extension'));
    if (await target.exists() && await target.length() == page.size) {
      return target.path;
    }
    final bytes = await _loadPage(page.index);
    if (bytes.length != page.size) {
      throw const HttpException('Die Remote-Comicseite ist unvollständig.');
    }
    final partial = File('${target.path}.part');
    await partial.writeAsBytes(bytes, flush: true);
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
    return target.path;
  }

  static Future<Directory> _createCacheDirectory() async {
    final root = Directory(
      p.join(Directory.systemTemp.path, 'fundus-remote-comic-pages'),
    );
    await root.create(recursive: true);
    final oldest = DateTime.now().subtract(const Duration(days: 1));
    await for (final entity in root.list(followLinks: false)) {
      try {
        if ((await entity.stat()).modified.isBefore(oldest)) {
          await entity.delete(recursive: true);
        }
      } catch (_) {}
    }
    return root.createTemp('chapter-');
  }

  @override
  Future<void> dispose() async {
    final directory = _cacheDirectory;
    _cacheDirectory = null;
    _materialized.clear();
    if (directory == null) return;
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } catch (_) {
      // A decoder may still briefly hold a page file. Stale cleanup retries
      // it the next time a remote comic source is opened.
    }
  }
}
