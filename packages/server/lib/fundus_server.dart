import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

export 'src/pairing.dart';

import 'src/pairing.dart';
import 'src/comic_archive.dart';

final class SharedFundusLibrary {
  SharedFundusLibrary({required this.name, required this.library})
    : _works = library.listWorks() {
    _worksById = {for (final work in _works) work.id: work};
  }

  final String name;
  final FundusLibrary library;
  final List<LibraryWorkSummary> _works;
  late final Map<String, LibraryWorkSummary> _worksById;
  final Map<String, List<LibraryPlaybackTrack>> _tracksByWork = {};
  final Map<String, ({LibraryWorkSummary work, LibraryPlaybackTrack track})>
  _tracksById = {};

  String get id => library.manifest.libraryId;
  List<LibraryWorkSummary> get works => _works;
  LibraryWorkSummary? findWork(String workId) => _worksById[workId];

  List<LibraryPlaybackTrack> tracksFor(String workId) =>
      _tracksByWork.putIfAbsent(workId, () {
        final tracks = library.playbackTracks(workId);
        final work = _worksById[workId];
        if (work != null) {
          for (final track in tracks) {
            _tracksById[track.fileId] = (work: work, track: track);
          }
        }
        return tracks;
      });

  ({LibraryWorkSummary work, LibraryPlaybackTrack track})? findTrack(
    String fileId,
  ) {
    final cached = _tracksById[fileId];
    if (cached != null) return cached;
    for (final work in _works) {
      tracksFor(work.id);
      final located = _tracksById[fileId];
      if (located != null) return located;
    }
    return null;
  }
}

final class FundusLibraryRegistry {
  final Map<String, SharedFundusLibrary> _libraries = {};

  List<SharedFundusLibrary> get libraries =>
      List.unmodifiable(_libraries.values);

  void register(FundusLibrary library, {required String name}) {
    _libraries[library.manifest.libraryId] = SharedFundusLibrary(
      name: name.trim().isEmpty ? 'Fundus' : name.trim(),
      library: library,
    );
  }

  SharedFundusLibrary? lookup(String id) => _libraries[id];

  SharedFundusLibrary? unregister(String id) => _libraries.remove(id);

  void close() {
    for (final entry in _libraries.values) {
      entry.library.close();
    }
    _libraries.clear();
  }
}

final class FundusServerRequestEvent {
  const FundusServerRequestEvent({
    required this.method,
    required this.resource,
    required this.statusCode,
  });

  final String method;
  final String resource;
  final int statusCode;
}

typedef FundusServerRequestObserver =
    void Function(FundusServerRequestEvent event);

final class FundusServerHandler {
  FundusServerHandler({
    required this.token,
    required this.serverId,
    this.serverName = 'Fundus',
    FundusLibraryRegistry? registry,
    this.pairingAuthority,
    this.requestObserver,
  }) : registry = registry ?? FundusLibraryRegistry();

  final String token;
  final String serverId;
  final String serverName;
  final FundusLibraryRegistry registry;
  final FundusPairingAuthority? pairingAuthority;
  final FundusServerRequestObserver? requestObserver;
  final ComicArchiveService _comicArchives = const ComicArchiveService();
  final Map<String, ({int size, int modified, ComicArchiveManifest manifest})>
  _comicManifestCache = {};

  Handler get handler {
    final router = Router()
      ..get('/health', _health)
      ..get('/api/v1/info', _capabilities)
      // Keep the capabilities probe compatible with older clients and
      // reverse proxies that still publish the historical /api/v1 prefix.
      ..get('/api/v1/capabilities', _capabilities)
      ..get('/v1/health', _health)
      ..post('/v1/pairing/claim', _claimPairing)
      ..get('/v1/capabilities', _capabilities)
      ..get('/v1/libraries', _libraries)
      ..get('/v1/libraries/<libraryId>/works', _works)
      ..get('/v1/libraries/<libraryId>/catalog', _catalog)
      ..get('/v1/libraries/<libraryId>/sync/changes', _syncChanges)
      ..post('/v1/libraries/<libraryId>/sync/changes', _pushSyncChanges)
      ..get('/v1/libraries/<libraryId>/works/<workId>', _work)
      ..get('/v1/libraries/<libraryId>/works/<workId>/cover', _cover)
      ..get('/v1/libraries/<libraryId>/files/<fileId>', _file)
      ..get('/v1/libraries/<libraryId>/files/<fileId>/comic/pages', _comicPages)
      ..get(
        '/v1/libraries/<libraryId>/files/<fileId>/comic/pages/<pageIndex>',
        _comicPage,
      )
      ..get('/v1/libraries/<libraryId>/files/<fileId>/content', _content)
      ..get('/v1/libraries/<libraryId>/playlists', _playlists)
      ..post('/v1/libraries/<libraryId>/playlists', _createPlaylist)
      ..get('/v1/libraries/<libraryId>/playlists/<playlistId>', _playlist)
      ..put('/v1/libraries/<libraryId>/playlists/<playlistId>', _savePlaylist)
      ..delete(
        '/v1/libraries/<libraryId>/playlists/<playlistId>',
        _deletePlaylist,
      )
      ..get('/v1/libraries/<libraryId>/collections', _collections)
      ..post('/v1/libraries/<libraryId>/collections', _createCollection)
      ..put(
        '/v1/libraries/<libraryId>/collections/<collectionId>',
        _saveCollection,
      )
      ..delete(
        '/v1/libraries/<libraryId>/collections/<collectionId>',
        _deleteCollection,
      )
      ..get('/v1/libraries/<libraryId>/playback-session', _playbackSession)
      ..put('/v1/libraries/<libraryId>/playback-session', _savePlaybackSession)
      ..get('/v1/libraries/<libraryId>/progress/<workId>', _progress)
      ..put('/v1/libraries/<libraryId>/progress/<workId>', _saveProgress)
      ..get('/v1/libraries/<libraryId>/annotations/<workId>', _annotations)
      ..post('/v1/libraries/<libraryId>/annotations/<workId>/notes', _saveNote)
      ..put('/v1/libraries/<libraryId>/annotations/<workId>/tags', _saveTags)
      ..post(
        '/v1/libraries/<libraryId>/annotations/<workId>/bookmarks',
        _saveBookmark,
      )
      ..delete(
        '/v1/libraries/<libraryId>/annotations/<workId>/bookmarks/<annotationId>',
        _deleteBookmark,
      )
      ..post(
        '/v1/libraries/<libraryId>/annotations/<workId>/highlights',
        _saveHighlight,
      )
      ..delete(
        '/v1/libraries/<libraryId>/annotations/<workId>/highlights/<annotationId>',
        _deleteHighlight,
      )
      ..get(
        '/v1/libraries/<libraryId>/reader-settings/<workId>/<deviceKey>/<readerKind>',
        _readerProfile,
      )
      ..put(
        '/v1/libraries/<libraryId>/reader-settings/<workId>/<deviceKey>/<readerKind>',
        _saveReaderProfile,
      )
      ..get(
        '/v1/libraries/<libraryId>/progress/<workId>/revisions',
        _progressRevisions,
      )
      ..post(
        '/v1/libraries/<libraryId>/progress/<workId>/revisions/<revision>/restore',
        _restoreProgressRevision,
      );
    return Pipeline()
        .addMiddleware(_requestDiagnostics())
        .addMiddleware(_authentication())
        .addMiddleware(_jsonErrors())
        .addMiddleware(_gzipJson())
        .addHandler(router.call);
  }

  Middleware _gzipJson() {
    return (inner) {
      return (request) async {
        final response = await inner(request);
        final acceptsGzip =
            request.headers['accept-encoding']
                ?.toLowerCase()
                .split(',')
                .map((value) => value.trim())
                .contains('gzip') ==
            true;
        final contentType = response.headers['content-type']?.toLowerCase();
        if (!acceptsGzip ||
            contentType?.startsWith('application/json') != true) {
          return response;
        }
        final bytes = await response.read().expand((chunk) => chunk).toList();
        if (bytes.length < 128) return response.change(body: bytes);
        final compressed = gzip.encode(bytes);
        return response.change(
          body: compressed,
          headers: {
            ...response.headers,
            'content-encoding': 'gzip',
            'content-length': '${compressed.length}',
            'vary': 'Accept-Encoding',
          },
        );
      };
    };
  }

  Middleware _requestDiagnostics() {
    return (inner) {
      return (request) async {
        final response = await inner(request);
        requestObserver?.call(
          FundusServerRequestEvent(
            method: request.method,
            resource: _resourceType(request.url.pathSegments),
            statusCode: response.statusCode,
          ),
        );
        return response;
      };
    };
  }

  static String _resourceType(List<String> segments) {
    if (segments.contains('comic')) return 'comic_pages';
    if (segments.contains('content')) return 'content';
    if (segments.contains('cover')) return 'cover';
    if (segments.contains('playlists')) return 'playlists';
    if (segments.contains('collections')) return 'collections';
    if (segments.contains('playback-session')) return 'playback_session';
    if (segments.contains('progress')) return 'progress';
    if (segments.contains('annotations')) return 'annotations';
    if (segments.contains('reader-settings')) return 'reader_settings';
    if (segments.contains('sync')) return 'sync';
    if (segments.contains('works')) return 'works';
    if (segments.contains('libraries')) return 'libraries';
    if (segments.contains('pairing')) return 'pairing';
    if (segments.contains('capabilities') || segments.contains('info')) {
      return 'capabilities';
    }
    if (segments.contains('health')) return 'health';
    return 'other';
  }

  Response _health(Request request) =>
      _json({'status': 'ok', 'server_id': serverId, 'api_version': 1});

  Future<Response> _claimPairing(Request request) async {
    final authority = pairingAuthority;
    if (authority == null || authority.activeSession == null) {
      return _json({'error': 'pairing_unavailable'}, statusCode: 403);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      return _badRequest('invalid_json');
    }
    if (decoded is! Map<String, dynamic>) {
      return _badRequest('invalid_pairing_request');
    }
    try {
      final result = await authority.claim(
        nonce: decoded['nonce'] is String ? decoded['nonce'] as String : '',
        pin: decoded['pin'] is String ? decoded['pin'] as String : '',
        deviceId: decoded['device_id'] is String
            ? decoded['device_id'] as String
            : '',
        deviceName: decoded['device_name'] is String
            ? decoded['device_name'] as String
            : '',
      );
      return _json({
        'server_id': serverId,
        'server_name': serverName,
        'device_id': result.device.id,
        'token': result.token,
      });
    } on FundusPairingException catch (error) {
      final code = switch (error.failure) {
        FundusPairingFailure.unavailable => 'pairing_unavailable',
        FundusPairingFailure.invalid => 'invalid_pairing_code',
        FundusPairingFailure.expired => 'pairing_expired',
        FundusPairingFailure.locked => 'pairing_locked',
      };
      return _json({'error': code}, statusCode: 403);
    }
  }

  Response _capabilities(Request request) => _json({
    'server_id': serverId,
    'server_name': serverName,
    'api_version': 1,
    'protocol_version': 1,
    'library_format_version': LibraryManifest.currentFormatVersion,
    'min_reader_version': LibraryManifest.currentReaderVersion,
    'capabilities': [
      'multiple_libraries',
      'work_browse',
      'catalog_delta',
      'cover',
      'chapters',
      'range_streaming',
      'comic_pages',
      'progress',
      'progress_history',
      'playlists',
      'collections',
      'collection_revisions',
      'playlist_revisions',
      'playback_session',
      'playback_session_revisions',
      'annotations',
      'portable_reader_profiles',
      'sync_journal',
      'sync_progress',
      'sync_annotations',
    ],
  });

  Response _libraries(Request request) => _json({
    'libraries': [
      for (final entry in registry.libraries)
        _libraryJson(entry, includeAdultExplicit: _canViewAdult(request)),
    ],
  });

  Response _works(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    return _json({
      'library_id': libraryId,
      'works': [
        for (final work in entry.works)
          if (_canViewWork(request, work))
            {..._workJson(work), 'cover_url': _coverUrl(libraryId, work)},
      ],
    });
  }

  /// Paginated catalog snapshot used by clients that keep a local metadata
  /// mirror. `since` is a stable offset into the current visible snapshot;
  /// callers can resume after a timeout without requesting the first page
  /// again. Visibility is evaluated before slicing so protected HHH works are
  /// never leaked through the cursor or the total count.
  Response _catalog(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final since = int.tryParse(request.url.queryParameters['since'] ?? '') ?? 0;
    final requestedLimit =
        int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 1000;
    final limit = requestedLimit.clamp(1, 1000);
    final visible = entry.works
        .where((work) => _canViewWork(request, work))
        .toList(growable: false);
    final etag = _catalogEtag(visible);
    if (request.url.queryParameters['etag'] == etag) {
      return _json({
        'library_id': libraryId,
        'works': const <Object?>[],
        'deleted': const <String>[],
        'next_cursor': 0,
        'has_more': false,
        'etag': etag,
        'not_modified': true,
      });
    }
    // Cursors address the visible snapshot, not the underlying unfiltered
    // list. Otherwise hiding an HHH work before the cursor would silently
    // skip a normal work on the next page.
    final offset = since.clamp(0, visible.length);
    final page = visible.skip(offset).take(limit).toList(growable: false);
    final nextCursor = offset + page.length;
    return _json({
      'library_id': libraryId,
      'works': [
        for (final work in page)
          {..._workJson(work), 'cover_url': _coverUrl(libraryId, work)},
      ],
      'deleted': const <String>[],
      'next_cursor': nextCursor,
      'has_more': nextCursor < visible.length,
      'etag': etag,
      'not_modified': false,
    });
  }

  String _catalogEtag(List<LibraryWorkSummary> works) {
    // Work ids alone are insufficient: a metadata edit must invalidate the
    // client mirror as well. Sorting keeps the fingerprint stable even when
    // the scanner returns the same works in a different order.
    final payload = [
      for (final work in [...works]..sort((a, b) => a.id.compareTo(b.id)))
        _workJson(work),
    ];
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  Future<Response> _work(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final work = entry.findWork(workId);
    if (work == null) return _notFound('work_not_found');
    if (!_canViewWork(request, work)) return _notFound('work_not_found');
    final chapters = work.kind == 'audiobook'
        ? await entry.library.playbackChapters(workId)
        : const <LibraryPlaybackChapter>[];
    return _json({
      ..._workJson(work),
      'files': [for (final track in entry.tracksFor(workId)) _trackJson(track)],
      'chapters': [for (final chapter in chapters) _chapterJson(chapter)],
      'cover_url': work.coverPath == null ? null : _coverUrl(libraryId, work),
    });
  }

  Future<Response> _cover(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final work = entry.findWork(workId);
    if (work == null) return _notFound('work_not_found');
    if (!_canViewWork(request, work)) return _notFound('cover_not_found');
    final path = work.coverPath;
    if (path == null) return _notFound('cover_not_found');
    return _serveFile(
      request,
      File(path),
      resourceId: 'cover-$workId',
      cacheControl: 'public, max-age=31536000, immutable',
    );
  }

  Response _file(Request request, String libraryId, String fileId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final located = entry.findTrack(fileId);
    if (located == null) return _notFound('file_not_found');
    if (!_canViewWork(request, located.work)) {
      return _notFound('file_not_found');
    }
    return _json({
      ..._trackJson(located.track),
      'work_id': located.work.id,
      'content_url': '/v1/libraries/$libraryId/files/$fileId/content',
    });
  }

  Future<Response> _content(
    Request request,
    String libraryId,
    String fileId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final located = entry.findTrack(fileId);
    if (located == null) return _notFound('file_not_found');
    if (!_canViewWork(request, located.work)) {
      return _notFound('file_not_found');
    }
    return _serveFile(
      request,
      File(located.track.absolutePath),
      resourceId: fileId,
    );
  }

  Future<Response> _comicPages(
    Request request,
    String libraryId,
    String fileId,
  ) async {
    final located = _comicTrack(libraryId, fileId);
    if (located == null) return _notFound('file_not_found');
    if (!_canViewWork(request, located.work)) {
      return _notFound('file_not_found');
    }
    try {
      final manifest = await _comicManifest(File(located.track.absolutePath));
      return _json({
        'file_id': fileId,
        'page_count': manifest.pages.length,
        'pages': [
          for (var index = 0; index < manifest.pages.length; index++)
            {
              'index': index,
              'id': manifest.pages[index].id,
              'name': manifest.pages[index].name,
              'size': manifest.pages[index].size,
              'mime_type': manifest.pages[index].mimeType,
              if (manifest.pages[index].width != null)
                'width': manifest.pages[index].width,
              if (manifest.pages[index].height != null)
                'height': manifest.pages[index].height,
            },
        ],
      });
    } on ComicArchiveException catch (error) {
      return _badRequest(error.code);
    }
  }

  Future<Response> _comicPage(
    Request request,
    String libraryId,
    String fileId,
    String pageIndex,
  ) async {
    final located = _comicTrack(libraryId, fileId);
    if (located == null) return _notFound('file_not_found');
    if (!_canViewWork(request, located.work)) {
      return _notFound('file_not_found');
    }
    final index = int.tryParse(pageIndex);
    if (index == null || index < 0) return _badRequest('invalid_page_index');
    try {
      final file = File(located.track.absolutePath);
      final manifest = await _comicManifest(file);
      if (index >= manifest.pages.length) return _notFound('page_not_found');
      final page = manifest.pages[index];
      final stat = await file.stat();
      final etag =
          '"comic-$fileId-$index-${stat.size}-${stat.modified.millisecondsSinceEpoch}"';
      final headers = <String, String>{
        'content-type': page.mimeType,
        'cache-control': 'private, max-age=3600',
        'etag': etag,
      };
      if (request.headers['if-none-match'] == etag) {
        return Response.notModified(headers: headers);
      }
      final bytes = await _comicArchives.readPage(file.path, page);
      return Response.ok(bytes, headers: headers);
    } on ComicArchiveException catch (error) {
      return _badRequest(error.code);
    }
  }

  ({LibraryWorkSummary work, LibraryPlaybackTrack track})? _comicTrack(
    String libraryId,
    String fileId,
  ) {
    final entry = registry.lookup(libraryId);
    final located = entry?.findTrack(fileId);
    if (located == null ||
        !located.track.absolutePath.toLowerCase().endsWith('.cbz')) {
      return null;
    }
    return located;
  }

  Future<ComicArchiveManifest> _comicManifest(File file) async {
    if (!await file.exists()) {
      throw const ComicArchiveException('comic_file_missing');
    }
    final stat = await file.stat();
    final cached = _comicManifestCache[file.path];
    final modified = stat.modified.millisecondsSinceEpoch;
    if (cached != null &&
        cached.size == stat.size &&
        cached.modified == modified) {
      return cached.manifest;
    }
    final manifest = await _comicArchives.inspect(file.path);
    _comicManifestCache[file.path] = (
      size: stat.size,
      modified: modified,
      manifest: manifest,
    );
    return manifest;
  }

  Response _playlists(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    return _json({
      'library_id': libraryId,
      'playlists': [
        for (final playlist in entry.library.listPlaylists())
          if (_canViewPlaylist(request, entry, playlist))
            _playlistJson(playlist),
      ],
    });
  }

  Response _collections(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final visibleWorkIds = {
      for (final work in entry.works)
        if (_canViewWork(request, work)) work.id,
    };
    return _json({
      'library_id': libraryId,
      'collections': [
        for (final collection in entry.library.listCollections())
          if (_collectionVisibility(
                request,
                entry,
                collection,
                visibleWorkIds: visibleWorkIds,
              )
              case final collectionWorkIds?)
            _collectionJson(collection, workIds: collectionWorkIds),
      ],
    });
  }

  Future<Response> _createCollection(Request request, String libraryId) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final decoded = await _readJson(request);
    if (decoded == null) return _badRequest('invalid_json');
    final values = _collectionValues(entry.library, decoded);
    if (values == null) return _badRequest('invalid_collection');
    if (!_canViewCollectionValues(request, entry, values)) {
      return _badRequest('work_not_found');
    }
    if (!_canViewCollectionRules(request, values.rules)) {
      return _badRequest('collection_not_allowed');
    }
    final collection = entry.library.saveCollection(
      name: values.name,
      parentId: values.parentId,
      kind: values.kind,
      rules: values.rules,
      workIds: values.workIds,
    );
    return _json(_collectionJson(collection), statusCode: HttpStatus.created);
  }

  Future<Response> _saveCollection(
    Request request,
    String libraryId,
    String collectionId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final current = entry.library.loadCollection(collectionId);
    if (current == null) return _notFound('collection_not_found');
    if (_collectionVisibility(
          request,
          entry,
          current,
          visibleWorkIds: {
            for (final work in entry.works)
              if (_canViewWork(request, work)) work.id,
          },
        ) ==
        null) {
      return _notFound('collection_not_found');
    }
    final decoded = await _readJson(request);
    if (decoded == null) return _badRequest('invalid_json');
    final expectedRevision = decoded['expected_revision'];
    if (expectedRevision is! int || expectedRevision < 1) {
      return _badRequest('invalid_collection_revision');
    }
    if (expectedRevision != current.revision) {
      return _json({
        'error': 'collection_conflict',
        'collection': _collectionJson(current),
      }, statusCode: HttpStatus.conflict);
    }
    final values = _collectionValues(entry.library, decoded);
    if (values == null) return _badRequest('invalid_collection');
    if (!_canViewCollectionValues(request, entry, values)) {
      return _badRequest('work_not_found');
    }
    if (!_canViewCollectionRules(request, values.rules)) {
      return _badRequest('collection_not_allowed');
    }
    final collection = entry.library.saveCollection(
      collectionId: collectionId,
      name: values.name,
      parentId: values.parentId,
      kind: values.kind,
      rules: values.rules,
      workIds: values.workIds,
    );
    return _json(_collectionJson(collection));
  }

  Response _deleteCollection(
    Request request,
    String libraryId,
    String collectionId,
  ) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final current = entry.library.loadCollection(collectionId);
    if (current == null) return _notFound('collection_not_found');
    final visibleIds = {
      for (final work in entry.works)
        if (_canViewWork(request, work)) work.id,
    };
    if (_collectionVisibility(
          request,
          entry,
          current,
          visibleWorkIds: visibleIds,
        ) ==
        null) {
      return _notFound('collection_not_found');
    }
    final expectedRevision = int.tryParse(
      request.url.queryParameters['expected_revision'] ?? '',
    );
    if (expectedRevision == null || expectedRevision < 1) {
      return _badRequest('invalid_collection_revision');
    }
    if (expectedRevision != current.revision) {
      return _json({
        'error': 'collection_conflict',
        'collection': _collectionJson(current),
      }, statusCode: HttpStatus.conflict);
    }
    entry.library.deleteCollection(collectionId);
    return Response(HttpStatus.noContent);
  }

  Response _playlist(Request request, String libraryId, String playlistId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final playlist = entry.library.loadPlaylist(playlistId);
    if (playlist == null) return _notFound('playlist_not_found');
    if (!_canViewPlaylist(request, entry, playlist)) {
      return _notFound('playlist_not_found');
    }
    return _json(_playlistJson(playlist));
  }

  Future<Response> _createPlaylist(Request request, String libraryId) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final decoded = await _readJson(request);
    if (decoded == null) return _badRequest('invalid_json');
    final values = _playlistValues(entry.library, decoded);
    if (values == null) return _badRequest('invalid_playlist');
    if (!_canViewWorkIds(request, entry, values.workIds)) {
      return _badRequest('work_not_found');
    }
    final playlist = entry.library.savePlaylist(
      name: values.name,
      mediaType: values.mediaType,
      workIds: values.workIds,
    );
    return _json(_playlistJson(playlist), statusCode: HttpStatus.created);
  }

  Future<Response> _savePlaylist(
    Request request,
    String libraryId,
    String playlistId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final current = entry.library.loadPlaylist(playlistId);
    if (current == null) return _notFound('playlist_not_found');
    if (!_canViewPlaylist(request, entry, current)) {
      return _notFound('playlist_not_found');
    }
    final decoded = await _readJson(request);
    if (decoded == null) return _badRequest('invalid_json');
    final expectedRevision = decoded['expected_revision'];
    if (expectedRevision is! int || expectedRevision < 1) {
      return _badRequest('invalid_playlist_revision');
    }
    if (expectedRevision != current.revision) {
      final visibleCurrent = _canViewPlaylist(request, entry, current)
          ? current
          : null;
      return _json({
        'error': 'playlist_conflict',
        'playlist': visibleCurrent == null
            ? null
            : _playlistJson(visibleCurrent),
      }, statusCode: HttpStatus.conflict);
    }
    final values = _playlistValues(entry.library, decoded);
    if (values == null) return _badRequest('invalid_playlist');
    if (!_canViewWorkIds(request, entry, values.workIds)) {
      return _badRequest('work_not_found');
    }
    final playlist = entry.library.savePlaylist(
      playlistId: playlistId,
      name: values.name,
      mediaType: values.mediaType,
      workIds: values.workIds,
    );
    return _json(_playlistJson(playlist));
  }

  Response _deletePlaylist(
    Request request,
    String libraryId,
    String playlistId,
  ) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final current = entry.library.loadPlaylist(playlistId);
    if (current == null) return _notFound('playlist_not_found');
    if (!_canViewPlaylist(request, entry, current)) {
      return _notFound('playlist_not_found');
    }
    final expectedRevision = int.tryParse(
      request.url.queryParameters['expected_revision'] ?? '',
    );
    if (expectedRevision == null || expectedRevision < 1) {
      return _badRequest('invalid_playlist_revision');
    }
    if (expectedRevision != current.revision) {
      final visibleCurrent = _canViewPlaylist(request, entry, current)
          ? current
          : null;
      return _json({
        'error': 'playlist_conflict',
        'playlist': visibleCurrent == null
            ? null
            : _playlistJson(visibleCurrent),
      }, statusCode: HttpStatus.conflict);
    }
    entry.library.deletePlaylist(playlistId);
    return Response(HttpStatus.noContent);
  }

  Response _playbackSession(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final session = entry.library.latestPlaybackSession();
    final visibleSession =
        session != null && _canViewPlaybackSession(request, entry, session)
        ? session
        : null;
    return _json({
      'library_id': libraryId,
      'session': visibleSession == null
          ? null
          : _playbackSessionJson(visibleSession),
    });
  }

  Future<Response> _savePlaybackSession(
    Request request,
    String libraryId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final decoded = await _readJson(request);
    if (decoded == null) return _badRequest('invalid_json');
    final expectedRevision = decoded['expected_revision'];
    if (expectedRevision is! int || expectedRevision < 0) {
      return _badRequest('invalid_session_revision');
    }
    final current = entry.library.latestPlaybackSession();
    if (expectedRevision != (current?.revision ?? 0)) {
      final visibleCurrent =
          current != null && _canViewPlaybackSession(request, entry, current)
          ? current
          : null;
      return _json({
        'error': 'playback_session_conflict',
        'session': visibleCurrent == null
            ? null
            : _playbackSessionJson(visibleCurrent),
      }, statusCode: HttpStatus.conflict);
    }
    final session = _playbackSessionFromJson(entry.library, libraryId, decoded);
    if (session == null) return _badRequest('invalid_playback_session');
    if (!_canViewPlaybackSession(request, entry, session)) {
      return _badRequest('work_not_found');
    }
    final saved = entry.library.savePlaybackSession(
      session,
      deviceId: decoded['device_id'] is String
          ? decoded['device_id'] as String
          : 'remote-peer',
      expectedRevision: expectedRevision,
    );
    return _json(_playbackSessionJson(saved));
  }

  static PlaybackSession? _playbackSessionFromJson(
    FundusLibrary library,
    String libraryId,
    Map<String, dynamic> decoded,
  ) {
    final itemsValue = decoded['items'];
    final currentIndex = decoded['current_index'];
    final positionValue = decoded['current_position'];
    final shuffleValue = decoded['shuffle_order'];
    final repeatValue = decoded['repeat_mode'];
    final playlistId = decoded['playlist_id'];
    final playlistRevision = decoded['playlist_revision'];
    if (itemsValue is! List ||
        itemsValue.isEmpty ||
        currentIndex is! int ||
        positionValue is! Map ||
        shuffleValue is! List ||
        shuffleValue.any((value) => value is! int) ||
        repeatValue is! String ||
        (playlistId != null && playlistId is! String) ||
        (playlistRevision != null && playlistRevision is! int)) {
      return null;
    }
    final items = <PlaybackSessionItem>[];
    for (var index = 0; index < itemsValue.length; index++) {
      final value = itemsValue[index];
      if (value is! Map ||
          value['work_id'] is! String ||
          value['file_ids'] is! List ||
          (value['file_ids'] as List).any((fileId) => fileId is! String)) {
        return null;
      }
      final workId = value['work_id'] as String;
      final work = _findWork(library, workId);
      if (work == null) return null;
      final validFileIds = library
          .playbackTracks(workId)
          .map((track) => track.fileId)
          .toSet();
      final fileIds = (value['file_ids'] as List).cast<String>();
      if (fileIds.any((fileId) => !validFileIds.contains(fileId))) return null;
      items.add(
        PlaybackSessionItem(workId: workId, fileIds: fileIds, position: index),
      );
    }
    if (items.map((item) => item.workId).toSet().length != items.length) {
      return null;
    }
    try {
      final session = PlaybackSession(
        id: 'current-$libraryId',
        playlistId: playlistId as String?,
        playlistRevision: playlistRevision as int?,
        items: items,
        currentIndex: currentIndex,
        currentPosition: MediaPosition.fromJson(
          positionValue.cast<String, Object?>(),
        ),
        repeatMode: RepeatMode.values.firstWhere(
          (mode) => mode.name == repeatValue,
        ),
        shuffleOrder: shuffleValue.cast<int>(),
      );
      session.validate();
      return session;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> _readJson(Request request) async {
    try {
      final decoded = jsonDecode(await request.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static ({String name, String? mediaType, List<String> workIds})?
  _playlistValues(FundusLibrary library, Map<String, dynamic> decoded) {
    final name = decoded['name'];
    final mediaType = decoded['media_type'];
    final workIds = decoded['work_ids'];
    if (name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 200 ||
        (mediaType != null && mediaType is! String) ||
        workIds is! List ||
        workIds.any((value) => value is! String)) {
      return null;
    }
    final normalizedIds = workIds.cast<String>();
    if (normalizedIds.toSet().length != normalizedIds.length ||
        normalizedIds.any((id) => _findWork(library, id) == null)) {
      return null;
    }
    final normalizedMediaType =
        mediaType is String && mediaType.trim().isNotEmpty
        ? mediaType.trim()
        : null;
    if (normalizedMediaType != null &&
        normalizedIds.any(
          (id) => _findWork(library, id)?.kind != normalizedMediaType,
        )) {
      return null;
    }
    return (
      name: name.trim(),
      mediaType: normalizedMediaType,
      workIds: normalizedIds,
    );
  }

  static ({
    String name,
    String? parentId,
    String kind,
    Map<String, Object?>? rules,
    List<String> workIds,
  })?
  _collectionValues(FundusLibrary library, Map<String, dynamic> decoded) {
    final name = decoded['name'];
    final parentId = decoded['parent_id'];
    final kind = decoded['kind'] ?? 'manual';
    final rules = decoded['rules'];
    final workIds = decoded['work_ids'] ?? const <Object?>[];
    if (name is! String ||
        name.trim().isEmpty ||
        name.trim().length > 200 ||
        (parentId != null && parentId is! String) ||
        (kind is! String || !const {'manual', 'smart'}.contains(kind)) ||
        (rules != null && rules is! Map) ||
        workIds is! List ||
        workIds.any((value) => value is! String)) {
      return null;
    }
    final normalizedParent = parentId is String && parentId.trim().isNotEmpty
        ? parentId.trim()
        : null;
    if (normalizedParent != null &&
        (library.loadCollection(normalizedParent) == null)) {
      return null;
    }
    final normalizedIds = workIds.cast<String>();
    if (normalizedIds.toSet().length != normalizedIds.length ||
        normalizedIds.any((id) => _findWork(library, id) == null)) {
      return null;
    }
    final normalizedRules = rules == null
        ? null
        : <String, Object?>{
            for (final entry in (rules as Map).entries)
              if (entry.key is String) entry.key as String: entry.value,
          };
    if (kind == 'smart' && normalizedRules == null) return null;
    return (
      name: name.trim(),
      parentId: normalizedParent,
      kind: kind,
      rules: normalizedRules,
      workIds: normalizedIds,
    );
  }

  bool _canViewCollectionValues(
    Request request,
    SharedFundusLibrary entry,
    ({
      String name,
      String? parentId,
      String kind,
      Map<String, Object?>? rules,
      List<String> workIds,
    })
    values,
  ) {
    if (!_canViewWorkIds(request, entry, values.workIds)) return false;
    if (values.parentId case final parentId?) {
      final parent = entry.library.loadCollection(parentId);
      if (parent == null ||
          _collectionVisibility(
                request,
                entry,
                parent,
                visibleWorkIds: {
                  for (final work in entry.works)
                    if (_canViewWork(request, work)) work.id,
                },
              ) ==
              null) {
        return false;
      }
    }
    return true;
  }

  bool _canViewCollectionRules(Request request, Map<String, Object?>? rules) {
    final sensitivities = rules?['sensitivities'];
    final targetsAdult =
        sensitivities is List &&
        sensitivities.whereType<String>().any(
          (value) => value == 'adult_explicit',
        );
    return !targetsAdult || _canViewAdult(request);
  }

  Response _progress(Request request, String libraryId, String workId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final progress = entry.library.loadProgress(workId);
    return _json({
      'library_id': libraryId,
      'work_id': workId,
      'progress': progress == null ? null : _progressJson(progress),
    });
  }

  Response _syncChanges(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final since = int.tryParse(request.url.queryParameters['since'] ?? '') ?? 0;
    final requestedLimit =
        int.tryParse(request.url.queryParameters['limit'] ?? '') ?? 500;
    final limit = requestedLimit.clamp(1, 500);
    final changes = entry.library
        .syncChanges(since: since < 0 ? 0 : since, limit: limit + 1)
        .where((change) => _canViewSyncChange(request, entry, change))
        .toList(growable: false);
    final hasMore = changes.length > limit;
    final visible = hasMore ? changes.take(limit).toList() : changes;
    final nextCursor = visible.isEmpty
        ? (since < 0 ? 0 : since)
        : visible.last.sequence;
    return _json({
      'library_id': libraryId,
      'entries': [for (final change in visible) change.toJson()],
      'next_cursor': nextCursor,
      'has_more': hasMore,
    });
  }

  Future<Response> _pushSyncChanges(Request request, String libraryId) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final decoded = await _readJson(request);
    final rawEntries = decoded?['entries'];
    if (rawEntries is! List || rawEntries.length > 500) {
      return _badRequest('invalid_sync_entries');
    }
    var applied = 0;
    var ignored = 0;
    for (final raw in rawEntries) {
      final change = LibrarySyncJournalEntry.fromJson(raw);
      if (change == null || change.operationId.trim().isEmpty) {
        return _badRequest('invalid_sync_entry');
      }
      if (entry.library.hasSyncOperation(change.operationId)) {
        ignored++;
        continue;
      }
      final result = _applySyncChange(request, entry, change);
      if (result == null) return _badRequest('invalid_sync_entry');
      if (result) {
        applied++;
      } else {
        entry.library.appendSyncChange(
          entity: change.entity,
          entityId: change.entityId,
          operation: change.operation,
          payload: change.payload,
          revision: change.revision,
          deviceId: change.deviceId,
          operationId: change.operationId,
          createdAt: change.createdAt,
        );
        applied++;
      }
    }
    return _json({
      'library_id': libraryId,
      'applied': applied,
      'ignored': ignored,
      'cursor': entry.library.syncCursor,
    });
  }

  /// Applies entities that have a concrete local representation. Unknown
  /// entities are still retained in the durable journal so a newer peer can
  /// apply them later; this is the forward-compatible part of the protocol.
  bool? _applySyncChange(
    Request request,
    SharedFundusLibrary entry,
    LibrarySyncJournalEntry change,
  ) {
    final payloadWorkId = change.payload['work_id'];
    if (payloadWorkId is String &&
        !_canViewWorkId(request, entry, payloadWorkId)) {
      return null;
    }
    if (change.entity != 'progress' || change.operation != 'upsert') {
      return false;
    }
    final workId = change.payload['work_id'] is String
        ? change.payload['work_id'] as String
        : change.entityId.split('/').first;
    final fileId = change.payload['file_id'];
    final position = change.payload['position'];
    if (workId.isEmpty || fileId is! String || position is! Map) return null;
    if (!_canViewWorkId(request, entry, workId)) return null;
    if (!entry.tracksFor(workId).any((track) => track.fileId == fileId)) {
      return null;
    }
    final decodedPosition = MediaPosition.fromJson(
      Map<String, Object?>.from(position),
    );
    entry.library.saveMediaProgress(
      workId: workId,
      fileId: fileId,
      position: decodedPosition,
      finished: change.payload['finished'] == true,
      deviceId: change.deviceId,
      operationId: change.operationId,
    );
    return true;
  }

  bool _canViewSyncChange(
    Request request,
    SharedFundusLibrary entry,
    LibrarySyncJournalEntry change,
  ) {
    final workId = change.payload['work_id'];
    return workId is! String || _canViewWorkId(request, entry, workId);
  }

  Response _annotations(Request request, String libraryId, String workId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    return _json(_annotationsJson(entry.library.loadAnnotations(workId)));
  }

  Future<Response> _saveNote(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final decoded = await _readJson(request);
    final markdown = decoded?['markdown'];
    if (markdown is! String || markdown.trim().isEmpty) {
      return _badRequest('invalid_note');
    }
    final annotations = await entry.library.saveWorkNote(workId, markdown);
    return _json(_annotationsJson(annotations));
  }

  Future<Response> _saveTags(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final decoded = await _readJson(request);
    final tags = decoded?['tags'];
    if (tags is! List || tags.any((value) => value is! String)) {
      return _badRequest('invalid_tags');
    }
    final annotations = await entry.library.replaceWorkTags(
      workId,
      tags.cast<String>(),
    );
    return _json(_annotationsJson(annotations));
  }

  Future<Response> _saveBookmark(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final decoded = await _readJson(request);
    final fileId = decoded?['file_id'];
    final encodedPosition = decoded?['position'];
    if (fileId is! String || encodedPosition is! Map) {
      return _badRequest('invalid_bookmark');
    }
    if (!entry.tracksFor(workId).any((track) => track.fileId == fileId)) {
      return _badRequest('file_not_in_work');
    }
    final MediaPosition position;
    try {
      position = MediaPosition.fromJson(
        Map<String, Object?>.from(encodedPosition),
      );
    } on Object {
      return _badRequest('invalid_bookmark');
    }
    final annotations = await entry.library.addMediaBookmark(
      workId: workId,
      fileId: fileId,
      position: position,
      label: decoded?['label'] is String ? decoded!['label'] as String : null,
      note: decoded?['note'] is String ? decoded!['note'] as String : null,
    );
    return _json(_annotationsJson(annotations));
  }

  Future<Response> _saveHighlight(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final decoded = await _readJson(request);
    final fileId = decoded?['file_id'];
    final encodedPosition = decoded?['position'];
    final quote = decoded?['quote'];
    if (fileId is! String || encodedPosition is! Map || quote is! String) {
      return _badRequest('invalid_highlight');
    }
    if (!entry.tracksFor(workId).any((track) => track.fileId == fileId)) {
      return _badRequest('file_not_in_work');
    }
    final MediaPosition position;
    try {
      position = MediaPosition.fromJson(
        Map<String, Object?>.from(encodedPosition),
      );
    } on Object {
      return _badRequest('invalid_highlight');
    }
    final annotations = await entry.library.addTextHighlight(
      workId: workId,
      fileId: fileId,
      position: position,
      quote: quote,
      color: decoded?['color'] is String
          ? decoded!['color'] as String
          : '#FFF176',
      note: decoded?['note'] is String ? decoded!['note'] as String : null,
    );
    return _json(_annotationsJson(annotations));
  }

  Future<Response> _deleteBookmark(
    Request request,
    String libraryId,
    String workId,
    String annotationId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    return _json(
      _annotationsJson(
        await entry.library.deleteBookmark(workId, annotationId),
      ),
    );
  }

  Future<Response> _deleteHighlight(
    Request request,
    String libraryId,
    String workId,
    String annotationId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    return _json(
      _annotationsJson(
        await entry.library.deleteHighlight(workId, annotationId),
      ),
    );
  }

  Map<String, Object?> _annotationsJson(WorkAnnotations annotations) => {
    'tags': annotations.tags,
    'notes': [
      for (final note in annotations.notes)
        {
          'id': note.id,
          'markdown': note.markdown,
          'created_at': note.createdAt.toUtc().toIso8601String(),
        },
    ],
    'bookmarks': [
      for (final bookmark in annotations.bookmarks)
        {
          'id': bookmark.id,
          'file_id': bookmark.fileId,
          'position': bookmark.mediaPosition.toJson(),
          'label': bookmark.label,
          'note': bookmark.note,
          'created_at': bookmark.createdAt.toUtc().toIso8601String(),
        },
    ],
    'highlights': [
      for (final highlight in annotations.highlights)
        {
          'id': highlight.id,
          'file_id': highlight.fileId,
          'position': highlight.mediaPosition.toJson(),
          'quote': highlight.quote,
          'color': highlight.color,
          'note': highlight.note,
          'created_at': highlight.createdAt.toUtc().toIso8601String(),
        },
    ],
  };

  Future<Response> _readerProfile(
    Request request,
    String libraryId,
    String workId,
    String deviceKey,
    String readerKind,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final profile = await entry.library.loadPortableReaderProfile(
      workId: workId,
      deviceKey: deviceKey,
      readerKind: readerKind,
    );
    return _json({'profile': profile});
  }

  Future<Response> _saveReaderProfile(
    Request request,
    String libraryId,
    String workId,
    String deviceKey,
    String readerKind,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final decoded = await _readJson(request);
    final profile = decoded?['profile'];
    if (profile is! Map<String, dynamic>) {
      return _badRequest('invalid_reader_profile');
    }
    await entry.library.savePortableReaderProfile(
      workId: workId,
      deviceKey: deviceKey,
      readerKind: readerKind,
      profile: Map<String, Object?>.from(profile),
    );
    return _json({'profile': profile});
  }

  Future<Response> _saveProgress(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await request.readAsString());
    } on FormatException {
      return _badRequest('invalid_json');
    }
    if (decoded is! Map<String, dynamic>) {
      return _badRequest('invalid_progress');
    }
    final fileId = decoded['file_id'];
    final seconds = decoded['position_seconds'];
    final encodedPosition = decoded['position'];
    final operationId = decoded['operation_id'];
    if (fileId is! String ||
        (encodedPosition is! Map &&
            (seconds is! num || !seconds.isFinite || seconds < 0)) ||
        operationId is! String ||
        operationId.trim().isEmpty) {
      return _badRequest('invalid_progress');
    }
    final validTrack = entry
        .tracksFor(workId)
        .any((track) => track.fileId == fileId);
    if (!validTrack) return _badRequest('file_not_in_work');
    final deviceId = decoded['device_id'] is String
        ? decoded['device_id'] as String
        : 'remote-peer';
    final LibraryPlaybackProgress progress;
    if (encodedPosition is Map) {
      final MediaPosition mediaPosition;
      try {
        mediaPosition = MediaPosition.fromJson(
          Map<String, Object?>.from(encodedPosition),
        );
      } on Object {
        return _badRequest('invalid_progress_position');
      }
      final numeric = mediaPosition.numericValue;
      final total = mediaPosition.total;
      if ((numeric != null && (!numeric.isFinite || numeric < 0)) ||
          (total != null &&
              (!total.isFinite ||
                  total < 0 ||
                  (numeric != null && total < numeric)))) {
        return _badRequest('invalid_progress_position');
      }
      progress = entry.library.saveMediaProgress(
        workId: workId,
        fileId: fileId,
        position: mediaPosition,
        finished: decoded['finished'] == true,
        deviceId: deviceId,
        operationId: operationId,
      );
    } else {
      final total = decoded['duration_seconds'];
      if (total != null &&
          (total is! num || !total.isFinite || total < seconds)) {
        return _badRequest('invalid_duration');
      }
      progress = entry.library.saveProgress(
        workId: workId,
        fileId: fileId,
        position: Duration(milliseconds: ((seconds as num) * 1000).round()),
        duration: total is num
            ? Duration(milliseconds: (total * 1000).round())
            : null,
        finished: decoded['finished'] == true,
        deviceId: deviceId,
        operationId: operationId,
      );
    }
    return _json(_progressJson(progress));
  }

  Response _progressRevisions(
    Request request,
    String libraryId,
    String workId,
  ) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    return _json({
      'work_id': workId,
      'revisions': [
        for (final revision in entry.library.listProgressRevisions(workId))
          _progressRevisionJson(revision),
      ],
    });
  }

  Future<Response> _restoreProgressRevision(
    Request request,
    String libraryId,
    String workId,
    String revision,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.library.isReadOnly) {
      return _json({'error': 'library_read_only'}, statusCode: 403);
    }
    if (!_canViewWorkId(request, entry, workId)) {
      return _notFound('work_not_found');
    }
    final parsedRevision = int.tryParse(revision);
    final decoded = await _readJson(request);
    if (parsedRevision == null || parsedRevision < 1 || decoded == null) {
      return _badRequest('invalid_progress_revision');
    }
    final operationId = decoded['operation_id'];
    if (operationId is! String || operationId.trim().isEmpty) {
      return _badRequest('invalid_progress_revision');
    }
    try {
      final restored = entry.library.restoreProgressRevision(
        workId: workId,
        revision: parsedRevision,
        deviceId: decoded['device_id'] is String
            ? decoded['device_id'] as String
            : 'remote-peer',
        operationId: operationId,
      );
      return _json(_progressJson(restored));
    } on StateError {
      return _notFound('progress_revision_not_found');
    }
  }

  Future<Response> _serveFile(
    Request request,
    File file, {
    required String resourceId,
    String? cacheControl,
  }) async {
    if (!await file.exists()) return _notFound('file_missing');
    final stat = await file.stat();
    final size = stat.size;
    final etag = '"$resourceId-$size-${stat.modified.millisecondsSinceEpoch}"';
    final headers = <String, String>{
      'accept-ranges': 'bytes',
      'content-type': _contentType(file.path),
      'etag': etag,
      if (cacheControl != null) 'cache-control': cacheControl,
    };
    if (request.headers['if-none-match'] == etag &&
        request.headers['range'] == null) {
      return Response.notModified(headers: headers);
    }
    final rangeHeader = request.headers['range'];
    if (rangeHeader == null) {
      return Response.ok(
        file.openRead(),
        headers: {...headers, 'content-length': '$size'},
      );
    }
    final range = _parseRange(rangeHeader, size);
    if (range == null) {
      return Response(
        HttpStatus.requestedRangeNotSatisfiable,
        headers: {...headers, 'content-range': 'bytes */$size'},
      );
    }
    return Response(
      HttpStatus.partialContent,
      body: file.openRead(range.start, range.end + 1),
      headers: {
        ...headers,
        'content-length': '${range.end - range.start + 1}',
        'content-range': 'bytes ${range.start}-${range.end}/$size',
      },
    );
  }

  Middleware _authentication() {
    return (inner) {
      return (request) {
        if (request.url.path == 'health' ||
            request.url.path == 'v1/health' ||
            request.url.path == 'v1/pairing/claim') {
          return inner(request);
        }
        final authorization = request.headers['authorization'];
        final bearer = authorization?.startsWith('Bearer ') == true
            ? authorization!.substring(7)
            : null;
        final directToken = _constantTimeEquals(authorization, 'Bearer $token');
        final deviceId = directToken
            ? null
            : pairingAuthority?.authorizeDevice(bearer);
        if (!directToken && deviceId == null) {
          return _json({'error': 'unauthorized'}, statusCode: 401);
        }
        return inner(
          request.change(
            context: {
              ...request.context,
              'fundus_device_id': deviceId,
              'fundus_adult_explicit':
                  directToken ||
                  (deviceId != null &&
                      (pairingAuthority?.adultExplicitAllowed(deviceId) ??
                          false)),
            },
          ),
        );
      };
    };
  }

  bool _canViewAdult(Request request) =>
      request.context['fundus_adult_explicit'] == true;

  bool _canViewWork(Request request, LibraryWorkSummary work) =>
      !work.isHhh || _canViewAdult(request);

  bool _canViewWorkId(
    Request request,
    SharedFundusLibrary entry,
    String workId,
  ) {
    final work = entry.findWork(workId);
    return work != null && _canViewWork(request, work);
  }

  bool _canViewWorkIds(
    Request request,
    SharedFundusLibrary entry,
    Iterable<String> workIds,
  ) => workIds.every((workId) => _canViewWorkId(request, entry, workId));

  bool _canViewPlaylist(
    Request request,
    SharedFundusLibrary entry,
    LibraryPlaylist playlist,
  ) => _canViewWorkIds(request, entry, playlist.workIds);

  Iterable<String>? _collectionVisibility(
    Request request,
    SharedFundusLibrary entry,
    LibraryCollection collection, {
    required Set<String> visibleWorkIds,
  }) {
    // A smart collection has no materialized membership in many older
    // libraries. Its rules still form a sensitive side-channel when they
    // explicitly target HHH, so keep that collection hidden unless the
    // requesting device is authorized.
    if (collection.isSmart) {
      final sensitivities = collection.rules?['sensitivities'];
      final targetsAdult =
          sensitivities is List &&
          sensitivities.whereType<String>().any(
            (value) => value == 'adult_explicit',
          );
      if (targetsAdult && !_canViewAdult(request)) return null;
      return collection.workIds
          .where(visibleWorkIds.contains)
          .toList(growable: false);
    }

    final allowed = collection.workIds
        .where(visibleWorkIds.contains)
        .toList(growable: false);
    // A genuinely empty manual collection is safe to expose and must remain
    // usable as a container that can be filled later. Hide only collections
    // whose non-empty membership became invisible through the HHH filter.
    return allowed.isEmpty && collection.workIds.isNotEmpty ? null : allowed;
  }

  bool _canViewPlaybackSession(
    Request request,
    SharedFundusLibrary entry,
    PlaybackSession session,
  ) => session.items.every(
    (item) => _canViewWorkId(request, entry, item.workId),
  );

  Middleware _jsonErrors() {
    return (inner) {
      return (request) async {
        try {
          return await inner(request);
        } catch (_) {
          return _json({'error': 'internal_error'}, statusCode: 500);
        }
      };
    };
  }

  static LibraryWorkSummary? _findWork(FundusLibrary library, String workId) =>
      library.listWorks().where((work) => work.id == workId).firstOrNull;

  static Map<String, Object?> _libraryJson(
    SharedFundusLibrary entry, {
    required bool includeAdultExplicit,
  }) {
    final workCount = includeAdultExplicit
        ? entry.works.length
        : entry.works.where((work) => !work.isHhh).length;
    return {
      'id': entry.id,
      'name': entry.name,
      'available': true,
      'read_only': entry.library.isReadOnly,
      'work_count': workCount,
    };
  }

  static Map<String, Object?> _workJson(LibraryWorkSummary work) => {
    'id': work.id,
    'kind': work.kind,
    'title': work.title,
    'authors': work.authors.isEmpty ? [work.author] : work.authors,
    'subtitle': work.subtitle,
    'series': work.series,
    'series_sequence': work.seriesSequence,
    'narrators': work.narrators,
    'language': work.language,
    'description': work.description,
    'publisher': work.publisher,
    'published_year': work.publishedYear,
    'file_count': work.fileCount,
    'tags': work.tags,
    if (work.contentSensitivity != null)
      'content_sensitivity': work.contentSensitivity,
    if (work.contentStyle != null) 'content_style': work.contentStyle,
    'added_at': work.addedAt.toUtc().toIso8601String(),
    'last_listened_at': work.lastListenedAt?.toUtc().toIso8601String(),
    'has_cover': work.coverPath != null,
    if (work.coverPath case final coverPath?)
      'cover_version': _coverVersion(coverPath),
    if (work.providerMetadata.isNotEmpty)
      'provider_metadata': work.providerMetadata,
    'progress': {
      'position_seconds': work.progressPosition?.inMilliseconds == null
          ? null
          : work.progressPosition!.inMilliseconds / 1000,
      'duration_seconds': work.progressDuration?.inMilliseconds == null
          ? null
          : work.progressDuration!.inMilliseconds / 1000,
      'track_index': work.progressTrackIndex,
      'finished': work.progressFinished,
    },
  };

  static String? _coverVersion(String path) {
    try {
      final stat = File(path).statSync();
      return '${stat.size}-${stat.modified.millisecondsSinceEpoch}';
    } on FileSystemException {
      return null;
    }
  }

  static String? _coverUrl(String libraryId, LibraryWorkSummary work) {
    if (work.coverPath == null) return null;
    final base = '/v1/libraries/$libraryId/works/${work.id}/cover';
    final version = _coverVersion(work.coverPath!);
    return version == null
        ? base
        : '$base?v=${Uri.encodeQueryComponent(version)}';
  }

  static Map<String, Object?> _trackJson(LibraryPlaybackTrack track) {
    final episode = track.episode ?? parseVideoEpisode(track.title);
    return {
      'id': track.fileId,
      'title': track.title,
      'position': track.index,
      'size': track.size,
      'mime_type': track.mimeType,
      'duration_seconds': track.duration?.inMilliseconds == null
          ? null
          : track.duration!.inMilliseconds / 1000,
      'audio': track.audioMetadata == null
          ? null
          : {
              'container': track.audioMetadata!.container,
              'codec': track.audioMetadata!.codec,
              'profile': track.audioMetadata!.profile,
              'channels': track.audioMetadata!.channels,
              'sample_rate_hz': track.audioMetadata!.sampleRateHz,
            },
      if (episode != null) 'episode': videoEpisodeToJson(episode),
    };
  }

  static Map<String, Object?> _chapterJson(LibraryPlaybackChapter chapter) => {
    'title': chapter.title,
    'file_id': chapter.fileId,
    'track_index': chapter.trackIndex,
    'position_seconds': chapter.position.inMilliseconds / 1000,
    'duration_seconds': chapter.duration?.inMilliseconds == null
        ? null
        : chapter.duration!.inMilliseconds / 1000,
  };

  Map<String, Object?> _progressJson(LibraryPlaybackProgress progress) => {
    'work_id': progress.workId,
    'file_id': progress.fileId,
    'position': progress.position.toJson(),
    'finished': progress.finished,
    'revision': progress.revision,
    'updated_at': progress.updatedAt.toUtc().toIso8601String(),
    'device_id': progress.deviceId,
    'device_name': _deviceName(progress.deviceId),
  };

  Map<String, Object?> _progressRevisionJson(
    LibraryPlaybackRevision revision,
  ) => {
    'work_id': revision.workId,
    'file_id': revision.fileId,
    'position': revision.position.toJson(),
    'finished': revision.finished,
    'revision': revision.revision,
    'created_at': revision.createdAt.toUtc().toIso8601String(),
    'device_id': revision.deviceId,
    'device_name': _deviceName(revision.deviceId),
  };

  String _deviceName(String deviceId) {
    if (deviceId == 'desktop-local' || deviceId == serverId) return serverName;
    return pairingAuthority?.devices
            .where((device) => device.id == deviceId)
            .firstOrNull
            ?.name ??
        'Unbekanntes Gerät';
  }

  static Map<String, Object?> _playlistJson(LibraryPlaylist playlist) => {
    'id': playlist.id,
    'name': playlist.name,
    'kind': playlist.kind.name,
    'media_type': playlist.mediaType,
    'work_ids': playlist.workIds,
    'revision': playlist.revision,
    'created_at': playlist.createdAt.toUtc().toIso8601String(),
    'updated_at': playlist.updatedAt.toUtc().toIso8601String(),
  };

  static Map<String, Object?> _collectionJson(
    LibraryCollection collection, {
    Iterable<String>? workIds,
  }) => {
    'id': collection.id,
    'name': collection.name,
    'parent_id': collection.parentId,
    'kind': collection.kind,
    if (collection.rules != null) 'rules': collection.rules,
    'work_ids': (workIds ?? collection.workIds).toList(growable: false),
    'revision': collection.revision,
    'created_at': collection.createdAt.toUtc().toIso8601String(),
    'updated_at': collection.updatedAt.toUtc().toIso8601String(),
  };

  static Map<String, Object?> _playbackSessionJson(PlaybackSession session) => {
    'id': session.id,
    'playlist_id': session.playlistId,
    'playlist_revision': session.playlistRevision,
    'items': [for (final item in session.items) item.toJson()],
    'current_index': session.currentIndex,
    'current_position': session.currentPosition.toJson(),
    'repeat_mode': session.repeatMode.name,
    'shuffle_order': session.shuffleOrder,
    'revision': session.revision,
    'updated_at': session.updatedAt?.toUtc().toIso8601String(),
  };

  static ({int start, int end})? _parseRange(String value, int size) {
    if (size <= 0 || !value.startsWith('bytes=') || value.contains(',')) {
      return null;
    }
    final parts = value.substring(6).split('-');
    if (parts.length != 2) return null;
    final startText = parts[0].trim();
    final endText = parts[1].trim();
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText);
      if (suffix == null || suffix <= 0) return null;
      final length = suffix > size ? size : suffix;
      return (start: size - length, end: size - 1);
    }
    final start = int.tryParse(startText);
    final requestedEnd = endText.isEmpty ? size - 1 : int.tryParse(endText);
    if (start == null ||
        requestedEnd == null ||
        start < 0 ||
        start >= size ||
        requestedEnd < start) {
      return null;
    }
    return (start: start, end: requestedEnd >= size ? size - 1 : requestedEnd);
  }

  static String _contentType(String path) {
    final extension = path.toLowerCase().split('.').last;
    return switch (extension) {
      'mp3' => 'audio/mpeg',
      'm4a' || 'm4b' => 'audio/mp4',
      'flac' => 'audio/flac',
      'ogg' || 'opus' => 'audio/ogg',
      'wav' => 'audio/wav',
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };
  }

  static bool _constantTimeEquals(String? actual, String expected) {
    if (actual == null) return false;
    final actualBytes = utf8.encode(actual);
    final expectedBytes = utf8.encode(expected);
    var difference = actualBytes.length ^ expectedBytes.length;
    final length = actualBytes.length > expectedBytes.length
        ? actualBytes.length
        : expectedBytes.length;
    for (var index = 0; index < length; index++) {
      final left = index < actualBytes.length ? actualBytes[index] : 0;
      final right = index < expectedBytes.length ? expectedBytes[index] : 0;
      difference |= left ^ right;
    }
    return difference == 0;
  }

  static Response _badRequest(String error) =>
      _json({'error': error}, statusCode: HttpStatus.badRequest);

  static Response _notFound(String error) =>
      _json({'error': error}, statusCode: HttpStatus.notFound);

  static Response _json(Object body, {int statusCode = 200}) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}
