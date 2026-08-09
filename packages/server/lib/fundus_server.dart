import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

export 'src/pairing.dart';

import 'src/pairing.dart';

final class SharedFundusLibrary {
  const SharedFundusLibrary({required this.name, required this.library});

  final String name;
  final FundusLibrary library;

  String get id => library.manifest.libraryId;
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

final class FundusServerHandler {
  FundusServerHandler({
    required this.token,
    required this.serverId,
    FundusLibraryRegistry? registry,
    this.pairingAuthority,
  }) : registry = registry ?? FundusLibraryRegistry();

  final String token;
  final String serverId;
  final FundusLibraryRegistry registry;
  final FundusPairingAuthority? pairingAuthority;

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
      ..get('/v1/libraries/<libraryId>/files/<fileId>/content', _content)
      ..get('/v1/libraries/<libraryId>/progress/<workId>', _progress)
      ..put('/v1/libraries/<libraryId>/progress/<workId>', _saveProgress);
    return Pipeline()
        .addMiddleware(_authentication())
        .addMiddleware(_jsonErrors())
        .addHandler(router.call);
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
    'api_version': 1,
    'library_format_version': LibraryManifest.currentFormatVersion,
    'min_reader_version': LibraryManifest.currentReaderVersion,
    'capabilities': [
      'multiple_libraries',
      'work_browse',
      'cover',
      'range_streaming',
      'progress',
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
        for (final work in entry.library.listWorks())
          {
            ..._workJson(work),
            'cover_url': work.coverPath == null
                ? null
                : '/v1/libraries/$libraryId/works/${work.id}/cover',
          },
      ],
    });
  }

  Response _work(Request request, String libraryId, String workId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final work = _findWork(entry.library, workId);
    if (work == null) return _notFound('work_not_found');
    return _json({
      ..._workJson(work),
      'files': [
        for (final track in entry.library.playbackTracks(workId))
          _trackJson(track),
      ],
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
    final work = _findWork(entry.library, workId);
    if (work == null) return _notFound('work_not_found');
    final path = work.coverPath;
    if (path == null) return _notFound('cover_not_found');
    return _serveFile(request, File(path), resourceId: 'cover-$workId');
  }

  Response _file(Request request, String libraryId, String fileId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    final located = _findTrack(entry.library, fileId);
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
    final located = _findTrack(entry.library, fileId);
    if (located == null) return _notFound('file_not_found');
    return _serveFile(
      request,
      File(located.track.absolutePath),
      resourceId: fileId,
    );
  }

  Response _progress(Request request, String libraryId, String workId) {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (_findWork(entry.library, workId) == null) {
      return _notFound('work_not_found');
    }
    final progress = entry.library.loadProgress(workId);
    return _json({
      'library_id': libraryId,
      'work_id': workId,
      'progress': progress == null ? null : _progressJson(progress),
    });
  }

  Future<Response> _saveProgress(
    Request request,
    String libraryId,
    String workId,
  ) async {
    final entry = registry.lookup(libraryId);
    if (entry == null) return _notFound('library_not_found');
    if (_findWork(entry.library, workId) == null) {
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
    final operationId = decoded['operation_id'];
    if (fileId is! String ||
        seconds is! num ||
        !seconds.isFinite ||
        seconds < 0 ||
        operationId is! String ||
        operationId.trim().isEmpty) {
      return _badRequest('invalid_progress');
    }
    final validTrack = entry.library
        .playbackTracks(workId)
        .any((track) => track.fileId == fileId);
    if (!validTrack) return _badRequest('file_not_in_work');
    final total = decoded['duration_seconds'];
    if (total != null &&
        (total is! num || !total.isFinite || total < seconds)) {
      return _badRequest('invalid_duration');
    }
    final progress = entry.library.saveProgress(
      workId: workId,
      fileId: fileId,
      position: Duration(milliseconds: (seconds * 1000).round()),
      duration: total is num
          ? Duration(milliseconds: (total * 1000).round())
          : null,
      finished: decoded['finished'] == true,
      deviceId: decoded['device_id'] is String
          ? decoded['device_id'] as String
          : 'remote-peer',
      operationId: operationId,
    );
    return _json(_progressJson(progress));
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

  static ({LibraryWorkSummary work, LibraryPlaybackTrack track})? _findTrack(
    FundusLibrary library,
    String fileId,
  ) {
    for (final work in library.listWorks()) {
      for (final track in library.playbackTracks(work.id)) {
        if (track.fileId == fileId) return (work: work, track: track);
      }
    }
    return null;
  }

  static Map<String, Object?> _libraryJson(SharedFundusLibrary entry) => {
    'id': entry.id,
    'name': entry.name,
    'available': true,
    'read_only': entry.library.isReadOnly,
    'work_count': entry.library.listWorks().length,
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
  };

  static Map<String, Object?> _progressJson(LibraryPlaybackProgress progress) =>
      {
        'work_id': progress.workId,
        'file_id': progress.fileId,
        'position': progress.position.toJson(),
        'finished': progress.finished,
        'revision': progress.revision,
        'updated_at': progress.updatedAt.toUtc().toIso8601String(),
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
