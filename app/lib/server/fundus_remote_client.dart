import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class FundusPairingInvitation {
  const FundusPairingInvitation({
    required this.baseUri,
    required this.serverId,
    required this.certificateFingerprint,
    required this.nonce,
    required this.pin,
    required this.expiresAt,
    this.serverName,
  });

  final Uri baseUri;
  final String serverId;
  final String certificateFingerprint;
  final String nonce;
  final String pin;
  final DateTime expiresAt;
  final String? serverName;

  FundusPairingInvitation withPin(String value) => FundusPairingInvitation(
    baseUri: baseUri,
    serverId: serverId,
    certificateFingerprint: certificateFingerprint,
    nonce: nonce,
    pin: value,
    expiresAt: expiresAt,
    serverName: serverName,
  );

  static FundusPairingInvitation parse(String source) {
    final value = jsonDecode(source);
    if (value is! Map ||
        value['type'] != 'fundus_pairing' ||
        value['version'] != 1) {
      throw const FormatException('Kein gültiger Fundus-Pairing-Code.');
    }
    final baseUri = Uri.tryParse('${value['base_url'] ?? ''}');
    final fingerprint = '${value['certificate_sha256'] ?? ''}'.toLowerCase();
    final expiresAt = DateTime.tryParse('${value['expires_at'] ?? ''}');
    if (baseUri == null ||
        baseUri.scheme != 'https' ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        fingerprint.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
        expiresAt == null) {
      throw const FormatException('Der Pairing-Code ist unvollständig.');
    }
    return FundusPairingInvitation(
      baseUri: baseUri,
      serverId: '${value['server_id']}',
      certificateFingerprint: fingerprint,
      nonce: '${value['nonce']}',
      pin: value['pin'] is String ? value['pin'] as String : '',
      expiresAt: expiresAt,
      serverName: value['server_name'] is String
          ? value['server_name'] as String
          : null,
    );
  }
}

final class FundusRemoteServer {
  const FundusRemoteServer({
    required this.id,
    required this.name,
    required this.baseUri,
    required this.certificateFingerprint,
    required this.token,
    this.serverName,
  });

  final String id;
  final String name;
  final Uri baseUri;
  final String certificateFingerprint;
  final String token;
  final String? serverName;

  FundusRemoteServer copyWith({
    String? name,
    Uri? baseUri,
    String? serverName,
  }) => FundusRemoteServer(
    id: id,
    name: name ?? this.name,
    baseUri: baseUri ?? this.baseUri,
    certificateFingerprint: certificateFingerprint,
    token: token,
    serverName: serverName ?? this.serverName,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'base_url': baseUri.toString(),
    'certificate_sha256': certificateFingerprint,
    'token': token,
    if (serverName != null) 'server_name': serverName,
  };

  static FundusRemoteServer? fromJson(Object? value) {
    if (value is! Map) return null;
    final baseUri = Uri.tryParse('${value['base_url'] ?? ''}');
    if (value['id'] is! String ||
        value['name'] is! String ||
        value['token'] is! String ||
        value['certificate_sha256'] is! String ||
        baseUri == null) {
      return null;
    }
    return FundusRemoteServer(
      id: value['id'] as String,
      name: value['name'] as String,
      baseUri: baseUri,
      certificateFingerprint: value['certificate_sha256'] as String,
      token: value['token'] as String,
      serverName: value['server_name'] is String
          ? value['server_name'] as String
          : null,
    );
  }
}

final class FundusRemoteLibrary {
  const FundusRemoteLibrary({
    required this.id,
    required this.name,
    required this.workCount,
  });

  final String id;
  final String name;
  final int workCount;
}

final class FundusRemoteLibraryReference {
  const FundusRemoteLibraryReference({
    required this.serverId,
    required this.libraryId,
    required this.name,
    required this.workCount,
  });

  final String serverId;
  final String libraryId;
  final String name;
  final int workCount;

  Map<String, Object?> toJson() => {
    'server_id': serverId,
    'library_id': libraryId,
    'name': name,
    'work_count': workCount,
  };

  static FundusRemoteLibraryReference? fromJson(Object? value) {
    if (value is! Map ||
        value['server_id'] is! String ||
        value['library_id'] is! String ||
        value['name'] is! String) {
      return null;
    }
    return FundusRemoteLibraryReference(
      serverId: value['server_id'] as String,
      libraryId: value['library_id'] as String,
      name: value['name'] as String,
      workCount: value['work_count'] is int ? value['work_count'] as int : 0,
    );
  }
}

final class FundusRemotePlaylist {
  const FundusRemotePlaylist({
    required this.id,
    required this.name,
    required this.kind,
    required this.workIds,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.mediaType,
  });

  final String id;
  final String name;
  final String kind;
  final String? mediaType;
  final List<String> workIds;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class FundusRemotePlaylistConflict implements Exception {
  const FundusRemotePlaylistConflict(this.current);

  final FundusRemotePlaylist current;

  @override
  String toString() =>
      'Die Playlist wurde auf einem anderen Gerät geändert (Revision ${current.revision}).';
}

final class FundusRemoteRequestException extends HttpException {
  FundusRemoteRequestException(this.statusCode, this.responseBody)
    : super('Serverfehler $statusCode.');

  final int statusCode;
  final String responseBody;
}

final class FundusRemoteWork {
  const FundusRemoteWork({
    required this.id,
    required this.title,
    required this.authors,
    required this.hasCover,
    this.kind = 'audiobook',
    this.subtitle,
    this.series,
    this.seriesSequence,
    this.narrators = const [],
    this.language,
    this.description,
    this.publisher,
    this.publishedYear,
    this.fileCount = 0,
    this.progressPosition,
    this.progressDuration,
    this.progressTrackIndex,
    this.progressFinished = false,
  });

  final String id;
  final String title;
  final List<String> authors;
  final bool hasCover;
  final String kind;
  final String? subtitle;
  final String? series;
  final num? seriesSequence;
  final List<String> narrators;
  final String? language;
  final String? description;
  final String? publisher;
  final int? publishedYear;
  final int fileCount;
  final Duration? progressPosition;
  final Duration? progressDuration;
  final int? progressTrackIndex;
  final bool progressFinished;
}

final class FundusRemoteTrack {
  const FundusRemoteTrack({
    required this.id,
    required this.title,
    required this.position,
    this.duration,
  });

  final String id;
  final String title;
  final int position;
  final Duration? duration;
}

final class FundusRemoteChapter {
  const FundusRemoteChapter({
    required this.title,
    required this.fileId,
    required this.trackIndex,
    required this.position,
    this.duration,
  });

  final String title;
  final String fileId;
  final int trackIndex;
  final Duration position;
  final Duration? duration;
}

final class FundusRemoteProgress {
  const FundusRemoteProgress({
    required this.fileId,
    required this.position,
    required this.finished,
    required this.revision,
  });

  final String? fileId;
  final Duration position;
  final bool finished;
  final int revision;
}

final class FundusRemoteWorkDetail {
  const FundusRemoteWorkDetail({
    required this.work,
    required this.tracks,
    required this.chapters,
  });

  final FundusRemoteWork work;
  final List<FundusRemoteTrack> tracks;
  final List<FundusRemoteChapter> chapters;
}

final class FundusRemoteStream {
  FundusRemoteStream(this.client, this.response);

  final HttpClient client;
  final HttpClientResponse response;

  void close() => client.close(force: true);
}

final class FundusRemoteServerStore {
  FundusRemoteServerStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _serversKey = 'fundus.remote_servers.v1';
  static const _deviceIdKey = 'fundus.device_id.v1';
  static const _deviceNameKey = 'fundus.device_name.v1';
  static const _librariesKey = 'fundus.remote_libraries.v1';
  final FlutterSecureStorage _storage;

  Future<List<FundusRemoteServer>> load() async {
    final source = await _storage.read(key: _serversKey);
    if (source == null) return const [];
    try {
      final value = jsonDecode(source);
      if (value is! List) return const [];
      return value
          .map(FundusRemoteServer.fromJson)
          .whereType<FundusRemoteServer>()
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(List<FundusRemoteServer> servers) => _storage.write(
    key: _serversKey,
    value: jsonEncode(servers.map((server) => server.toJson()).toList()),
  );

  Future<String> deviceId() async {
    final existing = await _storage.read(key: _deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final value = 'device-${_randomValue(18)}';
    await _storage.write(key: _deviceIdKey, value: value);
    return value;
  }

  Future<String> deviceName() async {
    final existing = await _storage.read(key: _deviceNameKey);
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();
    final value = _defaultDeviceName();
    await _storage.write(key: _deviceNameKey, value: value);
    return value;
  }

  Future<void> setDeviceName(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 80) return;
    await _storage.write(key: _deviceNameKey, value: normalized);
  }

  Future<List<FundusRemoteLibraryReference>> loadLibraryReferences() async {
    final source = await _storage.read(key: _librariesKey);
    if (source == null) return const [];
    try {
      final value = jsonDecode(source);
      if (value is! List) return const [];
      return value
          .map(FundusRemoteLibraryReference.fromJson)
          .whereType<FundusRemoteLibraryReference>()
          .toList(growable: false);
    } on FormatException {
      return const [];
    }
  }

  Future<void> rememberLibraries(
    FundusRemoteServer server,
    List<FundusRemoteLibrary> libraries,
  ) async {
    final current = await loadLibraryReferences();
    final updated = [
      ...current.where((item) => item.serverId != server.id),
      for (final library in libraries)
        FundusRemoteLibraryReference(
          serverId: server.id,
          libraryId: library.id,
          name: library.name,
          workCount: library.workCount,
        ),
    ];
    await _storage.write(
      key: _librariesKey,
      value: jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> forgetServerLibraries(String serverId) async {
    final current = await loadLibraryReferences();
    await _storage.write(
      key: _librariesKey,
      value: jsonEncode(
        current
            .where((item) => item.serverId != serverId)
            .map((item) => item.toJson())
            .toList(),
      ),
    );
  }

  static String _defaultDeviceName() => switch (Platform.operatingSystem) {
    'android' => 'Fundus auf Android',
    'ios' => 'Fundus auf iOS',
    'macos' => 'Fundus auf macOS',
    'windows' => 'Fundus auf Windows',
    'linux' => 'Fundus auf Linux',
    _ => 'Fundus-Gerät',
  };

  static String _randomValue(int count) {
    final random = Random.secure();
    final bytes = List<int>.generate(count, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

final class FundusRemoteClient {
  const FundusRemoteClient();

  Future<FundusRemoteServer> verifyEndpoint(
    FundusRemoteServer server,
    Uri baseUri,
  ) async {
    final candidate = server.copyWith(baseUri: baseUri);
    final value = await _json(candidate, '/v1/capabilities');
    if (value['server_id'] != server.id) {
      throw const HttpException(
        'Gefundene Geräteidentität stimmt nicht überein.',
      );
    }
    return candidate.copyWith(
      serverName: value['server_name'] is String
          ? value['server_name'] as String
          : server.serverName,
    );
  }

  Future<FundusRemoteServer> pair(
    FundusPairingInvitation invitation, {
    required String deviceId,
    required String deviceName,
  }) async {
    if (!DateTime.now().toUtc().isBefore(invitation.expiresAt.toUtc())) {
      throw const HttpException('Der Pairing-Code ist abgelaufen.');
    }
    final response = await _request(
      invitation.baseUri.resolve('/v1/pairing/claim'),
      fingerprint: invitation.certificateFingerprint,
      method: 'POST',
      body: jsonEncode({
        'nonce': invitation.nonce,
        'pin': invitation.pin,
        'device_id': deviceId,
        'device_name': deviceName,
      }),
    );
    final value = jsonDecode(utf8.decode(response));
    if (value is! Map || value['token'] is! String) {
      throw const HttpException('Ungültige Pairing-Antwort.');
    }
    final advertisedName = value['server_name'] is String
        ? value['server_name'] as String
        : invitation.serverName;
    return FundusRemoteServer(
      id: invitation.serverId,
      name: advertisedName?.trim().isNotEmpty == true
          ? advertisedName!.trim()
          : 'Fundus ${invitation.baseUri.host}',
      baseUri: invitation.baseUri,
      certificateFingerprint: invitation.certificateFingerprint,
      token: value['token'] as String,
      serverName: advertisedName,
    );
  }

  Future<List<FundusRemoteLibrary>> libraries(FundusRemoteServer server) async {
    final value = await _json(server, '/v1/libraries');
    final items = value['libraries'];
    if (items is! List) return const [];
    return [
      for (final item in items.whereType<Map>())
        if (item['id'] is String && item['name'] is String)
          FundusRemoteLibrary(
            id: item['id'] as String,
            name: item['name'] as String,
            workCount: item['work_count'] is int
                ? item['work_count'] as int
                : 0,
          ),
    ];
  }

  Future<List<FundusRemoteWork>> works(
    FundusRemoteServer server,
    String libraryId,
  ) async {
    final value = await _json(server, '/v1/libraries/$libraryId/works');
    final items = value['works'];
    if (items is! List) return const [];
    return [
      for (final item in items.whereType<Map>())
        if (item['id'] is String && item['title'] is String)
          FundusRemoteWork(
            id: item['id'] as String,
            title: item['title'] as String,
            authors: (item['authors'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            hasCover: item['has_cover'] == true,
            kind: item['kind'] is String ? item['kind'] as String : 'unknown',
            subtitle: item['subtitle'] is String
                ? item['subtitle'] as String
                : null,
            series: item['series'] is String ? item['series'] as String : null,
            seriesSequence: item['series_sequence'] is num
                ? item['series_sequence'] as num
                : null,
            narrators: (item['narrators'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            language: item['language'] is String
                ? item['language'] as String
                : null,
            description: item['description'] is String
                ? item['description'] as String
                : null,
            publisher: item['publisher'] is String
                ? item['publisher'] as String
                : null,
            publishedYear: item['published_year'] is int
                ? item['published_year'] as int
                : null,
            fileCount: item['file_count'] is int
                ? item['file_count'] as int
                : 0,
            progressPosition: _durationFromSeconds(
              (item['progress'] as Map?)?['position_seconds'],
            ),
            progressDuration: _durationFromSeconds(
              (item['progress'] as Map?)?['duration_seconds'],
            ),
            progressTrackIndex:
                (item['progress'] as Map?)?['track_index'] is int
                ? (item['progress'] as Map)['track_index'] as int
                : null,
            progressFinished: (item['progress'] as Map?)?['finished'] == true,
          ),
    ];
  }

  Future<List<FundusRemotePlaylist>> playlists(
    FundusRemoteServer server,
    String libraryId,
  ) async {
    final value = await _json(server, '/v1/libraries/$libraryId/playlists');
    final items = value['playlists'];
    if (items is! List) return const [];
    return items
        .map(_playlistFromJson)
        .whereType<FundusRemotePlaylist>()
        .toList();
  }

  Future<FundusRemotePlaylist> createPlaylist(
    FundusRemoteServer server, {
    required String libraryId,
    required String name,
    required List<String> workIds,
    String? mediaType,
  }) => _writePlaylist(
    server,
    '/v1/libraries/$libraryId/playlists',
    method: 'POST',
    body: {'name': name, 'media_type': mediaType, 'work_ids': workIds},
  );

  Future<FundusRemotePlaylist> savePlaylist(
    FundusRemoteServer server, {
    required String libraryId,
    required FundusRemotePlaylist playlist,
    required String name,
    required List<String> workIds,
    String? mediaType,
  }) => _writePlaylist(
    server,
    '/v1/libraries/$libraryId/playlists/${Uri.encodeComponent(playlist.id)}',
    method: 'PUT',
    body: {
      'name': name,
      'media_type': mediaType,
      'work_ids': workIds,
      'expected_revision': playlist.revision,
    },
  );

  Future<void> deletePlaylist(
    FundusRemoteServer server, {
    required String libraryId,
    required FundusRemotePlaylist playlist,
  }) async {
    final path =
        '/v1/libraries/$libraryId/playlists/${Uri.encodeComponent(playlist.id)}'
        '?expected_revision=${playlist.revision}';
    try {
      await _request(
        server.baseUri.resolve(path),
        fingerprint: server.certificateFingerprint,
        token: server.token,
        method: 'DELETE',
      );
    } on FundusRemoteRequestException catch (error) {
      _throwPlaylistConflict(error);
      rethrow;
    }
  }

  Future<FundusRemotePlaylist> _writePlaylist(
    FundusRemoteServer server,
    String path, {
    required String method,
    required Map<String, Object?> body,
  }) async {
    try {
      final bytes = await _request(
        server.baseUri.resolve(path),
        fingerprint: server.certificateFingerprint,
        token: server.token,
        method: method,
        body: jsonEncode(body),
      );
      final value = jsonDecode(utf8.decode(bytes));
      final playlist = _playlistFromJson(value);
      if (playlist == null) {
        throw const HttpException('Ungültige Playlist-Antwort.');
      }
      return playlist;
    } on FundusRemoteRequestException catch (error) {
      _throwPlaylistConflict(error);
      rethrow;
    }
  }

  static Never? _throwPlaylistConflict(FundusRemoteRequestException error) {
    if (error.statusCode != HttpStatus.conflict) return null;
    try {
      final value = jsonDecode(error.responseBody);
      final current = value is Map
          ? _playlistFromJson(value['playlist'])
          : null;
      if (current != null) throw FundusRemotePlaylistConflict(current);
    } on FormatException {
      return null;
    }
    return null;
  }

  static FundusRemotePlaylist? _playlistFromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['kind'] is! String ||
        value['work_ids'] is! List ||
        value['revision'] is! int) {
      return null;
    }
    final createdAt = DateTime.tryParse('${value['created_at'] ?? ''}');
    final updatedAt = DateTime.tryParse('${value['updated_at'] ?? ''}');
    if (createdAt == null || updatedAt == null) return null;
    return FundusRemotePlaylist(
      id: value['id'] as String,
      name: value['name'] as String,
      kind: value['kind'] as String,
      mediaType: value['media_type'] is String
          ? value['media_type'] as String
          : null,
      workIds: (value['work_ids'] as List).whereType<String>().toList(
        growable: false,
      ),
      revision: value['revision'] as int,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  static Duration? _durationFromSeconds(Object? value) =>
      value is num ? Duration(milliseconds: (value * 1000).round()) : null;

  Future<Uint8List> cover(
    FundusRemoteServer server,
    String libraryId,
    String workId,
  ) => _request(
    server.baseUri.resolve('/v1/libraries/$libraryId/works/$workId/cover'),
    fingerprint: server.certificateFingerprint,
    token: server.token,
  );

  Future<FundusRemoteWorkDetail> work(
    FundusRemoteServer server,
    String libraryId,
    FundusRemoteWork summary,
  ) async {
    final value = await _json(
      server,
      '/v1/libraries/$libraryId/works/${summary.id}',
    );
    final files = value['files'];
    final chapters = value['chapters'];
    return FundusRemoteWorkDetail(
      work: summary,
      tracks: [
        for (final item in (files is List ? files : const []).whereType<Map>())
          if (item['id'] is String && item['title'] is String)
            FundusRemoteTrack(
              id: item['id'] as String,
              title: item['title'] as String,
              position: item['position'] is int ? item['position'] as int : 0,
              duration: item['duration_seconds'] is num
                  ? Duration(
                      milliseconds: ((item['duration_seconds'] as num) * 1000)
                          .round(),
                    )
                  : null,
            ),
      ]..sort((a, b) => a.position.compareTo(b.position)),
      chapters: [
        for (final item
            in (chapters is List ? chapters : const []).whereType<Map>())
          if (item['title'] is String &&
              item['file_id'] is String &&
              item['track_index'] is int &&
              item['position_seconds'] is num)
            FundusRemoteChapter(
              title: item['title'] as String,
              fileId: item['file_id'] as String,
              trackIndex: item['track_index'] as int,
              position: Duration(
                milliseconds: ((item['position_seconds'] as num) * 1000)
                    .round(),
              ),
              duration: item['duration_seconds'] is num
                  ? Duration(
                      milliseconds: ((item['duration_seconds'] as num) * 1000)
                          .round(),
                    )
                  : null,
            ),
      ],
    );
  }

  Future<FundusRemoteProgress?> progress(
    FundusRemoteServer server,
    String libraryId,
    String workId,
  ) async {
    final value = await _json(
      server,
      '/v1/libraries/$libraryId/progress/$workId',
    );
    final progress = value['progress'];
    if (progress is! Map) return null;
    final position = progress['position'];
    if (position is! Map) return null;
    final seconds = position['numeric_value'];
    return FundusRemoteProgress(
      fileId: progress['file_id'] is String
          ? progress['file_id'] as String
          : position['file_id'] is String
          ? position['file_id'] as String
          : null,
      position: Duration(
        milliseconds: seconds is num ? (seconds * 1000).round() : 0,
      ),
      finished: progress['finished'] == true,
      revision: progress['revision'] is int ? progress['revision'] as int : 0,
    );
  }

  Future<FundusRemoteProgress> saveProgress(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String fileId,
    required Duration position,
    required Duration? duration,
    required bool finished,
    required String deviceId,
    required String operationId,
  }) async {
    final bytes = await _request(
      server.baseUri.resolve('/v1/libraries/$libraryId/progress/$workId'),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'PUT',
      body: jsonEncode({
        'operation_id': operationId,
        'device_id': deviceId,
        'file_id': fileId,
        'position_seconds': position.inMilliseconds / 1000,
        if (duration != null)
          'duration_seconds': duration.inMilliseconds / 1000,
        'finished': finished,
      }),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) {
      throw const HttpException('Ungültige Fortschrittsantwort.');
    }
    final positionValue = value['position'];
    final seconds = positionValue is Map ? positionValue['numeric_value'] : 0;
    return FundusRemoteProgress(
      fileId: value['file_id'] is String ? value['file_id'] as String : fileId,
      position: Duration(
        milliseconds: seconds is num ? (seconds * 1000).round() : 0,
      ),
      finished: value['finished'] == true,
      revision: value['revision'] is int ? value['revision'] as int : 0,
    );
  }

  Future<FundusRemoteStream> openContent(
    FundusRemoteServer server, {
    required String libraryId,
    required String fileId,
    String? range,
  }) => _open(
    server.baseUri.resolve('/v1/libraries/$libraryId/files/$fileId/content'),
    fingerprint: server.certificateFingerprint,
    token: server.token,
    range: range,
  );

  Future<Map<String, dynamic>> _json(
    FundusRemoteServer server,
    String path,
  ) async {
    final bytes = await _request(
      server.baseUri.resolve(path),
      fingerprint: server.certificateFingerprint,
      token: server.token,
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, dynamic>) {
      throw const HttpException('Ungültige Serverantwort.');
    }
    return value;
  }

  Future<Uint8List> _request(
    Uri uri, {
    required String fingerprint,
    String method = 'GET',
    String? token,
    String? body,
  }) async {
    final stream = await _open(
      uri,
      fingerprint: fingerprint,
      method: method,
      token: token,
      body: body,
    );
    try {
      final bytes = Uint8List.fromList(
        await stream.response
            .timeout(const Duration(seconds: 20))
            .expand((chunk) => chunk)
            .toList(),
      );
      return bytes;
    } finally {
      stream.close();
    }
  }

  Future<FundusRemoteStream> _open(
    Uri uri, {
    required String fingerprint,
    String method = 'GET',
    String? token,
    String? body,
    String? range,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (certificate, host, port) =>
        _fingerprint(certificate) == fingerprint;
    try {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      final certificate = response.certificate;
      if (certificate == null || _fingerprint(certificate) != fingerprint) {
        await response.drain<void>();
        throw const TlsException(
          'Zertifikat stimmt nicht mit dem QR-Code überein.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final responseBody = await utf8.decoder.bind(response).join();
        throw FundusRemoteRequestException(response.statusCode, responseBody);
      }
      return FundusRemoteStream(client, response);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  static String _fingerprint(X509Certificate certificate) =>
      sha256.convert(certificate.der).toString();
}
