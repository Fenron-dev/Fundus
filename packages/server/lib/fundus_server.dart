import 'dart:convert';
import 'dart:io';

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
      ..get('/v1/health', _health)
      ..post('/v1/pairing/claim', _claimPairing)
      ..get('/v1/capabilities', _capabilities)
      ..get('/v1/libraries', _libraries)
      ..get('/v1/libraries/<libraryId>/works', _works)
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
        .addHandler(router.call);
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
    if (segments.contains('playback-session')) return 'playback_session';
    if (segments.contains('progress')) return 'progress';
    if (segments.contains('annotations')) return 'annotations';
    if (segments.contains('reader-settings')) return 'reader_settings';
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
    'library_format_version': LibraryManifest.currentFormatVersion,
    'min_reader_version': LibraryManifest.currentReaderVersion,
    'capabilities': [
      'multiple_libraries',
      'work_browse',
      'cover',
      'chapters',
      'range_streaming',
      'comic_pages',
      'progress',
      'progress_history',
      'playlists',
      'playlist_revisions',
      'playback_session',
      'playback_session_revisions',
      'annotations',
      'portable_reader_profiles',
    ],
  });

  Response _libraries(Request request) => _json({
    'libraries': [for (final entry in registry.libraries) _libraryJson(entry)],
  });

  Response _works(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    return _json({
      'library_id': libraryId,
      'works': [
        for (final work in entry.works)
          {
            ..._workJson(work),
            'cover_url': work.coverPath == null
                ? null
                : '/v1/libraries/$libraryId/works/${work.id}/cover',
          },
      ],
    });
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
    final chapters = work.kind == 'audiobook'
        ? await entry.library.playbackChapters(workId)
        : const <LibraryPlaybackChapter>[];
    return _json({
      ..._workJson(work),
      'files': [for (final track in entry.tracksFor(workId)) _trackJson(track)],
      'chapters': [for (final chapter in chapters) _chapterJson(chapter)],
      'cover_url': work.coverPath == null
          ? null
          : '/v1/libraries/$libraryId/works/$workId/cover',
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
    final path = work.coverPath;
    if (path == null) return _notFound('cover_not_found');
    return _serveFile(request, File(path), resourceId: 'cover-$workId');
  }

  Response _file(Request request, String libraryId, String fileId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final located = entry.findTrack(fileId);
    if (located == null) return _notFound('file_not_found');
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
          _playlistJson(playlist),
      ],
    });
  }

  Response _playlist(Request request, String libraryId, String playlistId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final playlist = entry.library.loadPlaylist(playlistId);
    if (playlist == null) return _notFound('playlist_not_found');
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
    final decoded = await _readJson(request);
    if (decoded == null) return _badRequest('invalid_json');
    final expectedRevision = decoded['expected_revision'];
    if (expectedRevision is! int || expectedRevision < 1) {
      return _badRequest('invalid_playlist_revision');
    }
    if (expectedRevision != current.revision) {
      return _json({
        'error': 'playlist_conflict',
        'playlist': _playlistJson(current),
      }, statusCode: HttpStatus.conflict);
    }
    final values = _playlistValues(entry.library, decoded);
    if (values == null) return _badRequest('invalid_playlist');
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
    final expectedRevision = int.tryParse(
      request.url.queryParameters['expected_revision'] ?? '',
    );
    if (expectedRevision == null || expectedRevision < 1) {
      return _badRequest('invalid_playlist_revision');
    }
    if (expectedRevision != current.revision) {
      return _json({
        'error': 'playlist_conflict',
        'playlist': _playlistJson(current),
      }, statusCode: HttpStatus.conflict);
    }
    entry.library.deletePlaylist(playlistId);
    return Response(HttpStatus.noContent);
  }

  Response _playbackSession(Request request, String libraryId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final session = entry.library.latestPlaybackSession();
    return _json({
      'library_id': libraryId,
      'session': session == null ? null : _playbackSessionJson(session),
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
      return _json({
        'error': 'playback_session_conflict',
        'session': current == null ? null : _playbackSessionJson(current),
      }, statusCode: HttpStatus.conflict);
    }
    final session = _playbackSessionFromJson(entry.library, libraryId, decoded);
    if (session == null) return _badRequest('invalid_playback_session');
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

  Response _progress(Request request, String libraryId, String workId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.findWork(workId) == null) {
      return _notFound('work_not_found');
    }
    final progress = entry.library.loadProgress(workId);
    return _json({
      'library_id': libraryId,
      'work_id': workId,
      'progress': progress == null ? null : _progressJson(progress),
    });
  }

  Response _annotations(Request request, String libraryId, String workId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (entry.findWork(workId) == null) {
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
    if (entry.findWork(workId) == null) {
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
    if (entry.findWork(workId) == null) {
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
    if (entry.findWork(workId) == null) return _notFound('work_not_found');
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
    if (entry.findWork(workId) == null) return _notFound('work_not_found');
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
    if (entry.findWork(workId) == null) return _notFound('work_not_found');
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
    if (entry.findWork(workId) == null) return _notFound('work_not_found');
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
    if (entry.findWork(workId) == null) {
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
    if (entry.findWork(workId) == null) {
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
    if (entry.findWork(workId) == null) {
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
    if (entry.findWork(workId) == null) {
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
  }) async {
    if (!await file.exists()) return _notFound('file_missing');
    final stat = await file.stat();
    final size = stat.size;
    final etag = '"$resourceId-$size-${stat.modified.millisecondsSinceEpoch}"';
    final headers = <String, String>{
      'accept-ranges': 'bytes',
      'content-type': _contentType(file.path),
      'etag': etag,
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
        if (!_constantTimeEquals(authorization, 'Bearer $token') &&
            !(pairingAuthority?.authorize(bearer) ?? false)) {
          return _json({'error': 'unauthorized'}, statusCode: 401);
        }
        return inner(request);
      };
    };
  }

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

  static Map<String, Object?> _libraryJson(SharedFundusLibrary entry) => {
    'id': entry.id,
    'name': entry.name,
    'available': true,
    'read_only': entry.library.isReadOnly,
    'work_count': entry.works.length,
  };

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
    'added_at': work.addedAt.toUtc().toIso8601String(),
    'last_listened_at': work.lastListenedAt?.toUtc().toIso8601String(),
    'has_cover': work.coverPath != null,
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

  static Map<String, Object?> _trackJson(LibraryPlaybackTrack track) => {
    'id': track.fileId,
    'title': track.title,
    'position': track.index,
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
  };

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
