import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus_core/fundus_core.dart';

import '../diagnostics/fundus_diagnostics.dart';

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

/// A collection exposed by a remote Fundus library. Collections are
/// provider-neutral virtual folders and may contain works of different kinds.
final class FundusRemoteCollection {
  const FundusRemoteCollection({
    required this.id,
    required this.name,
    required this.kind,
    required this.workIds,
    required this.createdAt,
    required this.revision,
    required this.updatedAt,
    this.parentId,
    this.rules,
  });

  final String id;
  final String name;
  final String kind;
  final String? parentId;
  final Map<String, Object?>? rules;
  final List<String> workIds;
  final DateTime createdAt;
  final int revision;
  final DateTime updatedAt;

  bool get isSmart => kind == 'smart';
}

final class FundusRemotePlaylistConflict implements Exception {
  const FundusRemotePlaylistConflict(this.current);

  final FundusRemotePlaylist current;

  @override
  String toString() =>
      'Die Playlist wurde auf einem anderen Gerät geändert (Revision ${current.revision}).';
}

final class FundusRemoteCollectionConflict implements Exception {
  const FundusRemoteCollectionConflict(this.current);

  final FundusRemoteCollection current;

  @override
  String toString() =>
      'Die Sammlung wurde auf einem anderen Gerät geändert (Revision ${current.revision}).';
}

final class FundusRemoteRequestException extends HttpException {
  FundusRemoteRequestException(
    this.statusCode,
    this.responseBody, {
    this.requestUri,
  }) : super(
         requestUri == null
             ? 'Serverfehler $statusCode.'
             : 'Serverfehler $statusCode bei ${requestUri.path}.',
       );

  final int statusCode;
  final String responseBody;
  final Uri? requestUri;
}

final class FundusRemotePlaybackSessionConflict implements Exception {
  const FundusRemotePlaybackSessionConflict(this.current);

  final PlaybackSession? current;

  @override
  String toString() =>
      'Die Wiedergabe-Queue wurde auf einem anderen Gerät geändert.';
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
    this.contentSensitivity,
    this.contentStyle,
    this.tags = const [],
    this.addedAt,
    this.lastListenedAt,
    this.providerMetadata = const {},
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
  final String? contentSensitivity;
  final String? contentStyle;
  final List<String> tags;
  final DateTime? addedAt;
  final DateTime? lastListenedAt;
  final Map<String, Object?> providerMetadata;

  bool get isHhh => contentSensitivity == 'adult_explicit';

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'authors': authors,
    'has_cover': hasCover,
    'kind': kind,
    if (subtitle != null) 'subtitle': subtitle,
    if (series != null) 'series': series,
    if (seriesSequence != null) 'series_sequence': seriesSequence,
    'narrators': narrators,
    if (language != null) 'language': language,
    if (description != null) 'description': description,
    if (publisher != null) 'publisher': publisher,
    if (publishedYear != null) 'published_year': publishedYear,
    'file_count': fileCount,
    if (progressPosition != null)
      'progress_position_seconds': progressPosition!.inMilliseconds / 1000,
    if (progressDuration != null)
      'progress_duration_seconds': progressDuration!.inMilliseconds / 1000,
    if (progressTrackIndex != null) 'progress_track_index': progressTrackIndex,
    'progress_finished': progressFinished,
    if (contentSensitivity != null) 'content_sensitivity': contentSensitivity,
    if (contentStyle != null) 'content_style': contentStyle,
    'tags': tags,
    if (addedAt != null) 'added_at': addedAt!.toUtc().toIso8601String(),
    if (lastListenedAt != null)
      'last_listened_at': lastListenedAt!.toUtc().toIso8601String(),
    'provider_metadata': providerMetadata,
  };

  static FundusRemoteWork? fromJson(Object? value) {
    if (value is! Map || value['id'] is! String || value['title'] is! String) {
      return null;
    }
    List<String> strings(Object? raw) => raw is List
        ? raw.whereType<String>().toList(growable: false)
        : const [];
    Duration? duration(Object? raw) => raw is num
        ? Duration(milliseconds: (raw.toDouble() * 1000).round())
        : null;
    final provider = value['provider_metadata'];
    return FundusRemoteWork(
      id: value['id'] as String,
      title: value['title'] as String,
      authors: strings(value['authors']),
      hasCover: value['has_cover'] == true,
      kind: value['kind'] is String ? value['kind'] as String : 'unknown',
      subtitle: value['subtitle'] is String
          ? value['subtitle'] as String
          : null,
      series: value['series'] is String ? value['series'] as String : null,
      seriesSequence: value['series_sequence'] is num
          ? value['series_sequence'] as num
          : null,
      narrators: strings(value['narrators']),
      language: value['language'] is String
          ? value['language'] as String
          : null,
      description: value['description'] is String
          ? value['description'] as String
          : null,
      publisher: value['publisher'] is String
          ? value['publisher'] as String
          : null,
      publishedYear: value['published_year'] is int
          ? value['published_year'] as int
          : null,
      fileCount: value['file_count'] is int ? value['file_count'] as int : 0,
      progressPosition: duration(value['progress_position_seconds']),
      progressDuration: duration(value['progress_duration_seconds']),
      progressTrackIndex: value['progress_track_index'] is int
          ? value['progress_track_index'] as int
          : null,
      progressFinished: value['progress_finished'] == true,
      contentSensitivity: value['content_sensitivity'] is String
          ? value['content_sensitivity'] as String
          : null,
      contentStyle: value['content_style'] is String
          ? value['content_style'] as String
          : null,
      tags: strings(value['tags']),
      addedAt: DateTime.tryParse('${value['added_at'] ?? ''}'),
      lastListenedAt: DateTime.tryParse('${value['last_listened_at'] ?? ''}'),
      providerMetadata: provider is Map
          ? {
              for (final entry in provider.entries)
                if (entry.key is String && entry.value != null)
                  entry.key as String: entry.value,
            }
          : const {},
    );
  }
}

final class FundusRemoteCatalogPage {
  const FundusRemoteCatalogPage({
    required this.works,
    required this.deleted,
    required this.nextCursor,
    required this.hasMore,
    this.etag,
    this.notModified = false,
  });

  final List<FundusRemoteWork> works;
  final List<String> deleted;
  final int nextCursor;
  final bool hasMore;
  final String? etag;
  final bool notModified;
}

final class FundusRemoteTrack {
  const FundusRemoteTrack({
    required this.id,
    required this.title,
    required this.position,
    this.size,
    this.mimeType,
    this.duration,
    this.audioMetadata,
    this.episode,
  });

  final String id;
  final String title;
  final int position;
  final int? size;
  final String? mimeType;
  final Duration? duration;
  final AudioTechnicalMetadata? audioMetadata;
  final VideoEpisodeIdentity? episode;
}

final class FundusRemoteComicPage {
  const FundusRemoteComicPage({
    required this.index,
    required this.id,
    required this.name,
    required this.size,
    required this.mimeType,
    this.width,
    this.height,
  });

  final int index;
  final String id;
  final String name;
  final int size;
  final String mimeType;
  final int? width;
  final int? height;
}

final class FundusRemoteComicManifest {
  const FundusRemoteComicManifest({required this.fileId, required this.pages});

  final String fileId;
  final List<FundusRemoteComicPage> pages;
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
    this.duration,
    this.mediaPosition,
    this.deviceId,
    this.deviceName,
    this.updatedAt,
    this.pendingSync = false,
  });

  final String? fileId;
  final Duration position;
  final Duration? duration;
  final MediaPosition? mediaPosition;
  final bool finished;
  final int revision;
  final String? deviceId;
  final String? deviceName;
  final DateTime? updatedAt;

  /// True only for a local change that the server has not acknowledged yet.
  final bool pendingSync;
}

final class FundusRemoteProgressRevision {
  const FundusRemoteProgressRevision({
    required this.fileId,
    required this.position,
    required this.finished,
    required this.revision,
    required this.createdAt,
    required this.deviceId,
    required this.deviceName,
    required this.mediaPosition,
    this.duration,
  });

  final String? fileId;
  final Duration position;
  final Duration? duration;
  final bool finished;
  final int revision;
  final DateTime createdAt;
  final String deviceId;
  final String deviceName;
  final MediaPosition mediaPosition;
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
    Map<String, dynamic> value;
    try {
      value = await _json(candidate, '/v1/capabilities');
    } on FundusRemoteRequestException catch (error) {
      // Older desktop builds exposed the same endpoint as /api/v1/info.
      // Keep reconnects after an update/sleep resilient while the server is
      // upgraded, and make the fallback visible in diagnostics.
      if (error.statusCode != HttpStatus.notFound) rethrow;
      value = await _json(candidate, '/api/v1/info');
      unawaited(
        FundusDiagnostics.instance.record('remote.endpoint_fallback', {
          'base_url': baseUri.toString(),
          'from': '/v1/capabilities',
          'to': '/api/v1/info',
          'status': error.statusCode,
        }),
      );
    }
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
            contentSensitivity: item['content_sensitivity'] is String
                ? item['content_sensitivity'] as String
                : null,
            contentStyle: item['content_style'] is String
                ? item['content_style'] as String
                : null,
            tags: (item['tags'] as List? ?? const [])
                .whereType<String>()
                .toList(growable: false),
            addedAt: DateTime.tryParse('${item['added_at'] ?? ''}'),
            lastListenedAt: DateTime.tryParse(
              '${item['last_listened_at'] ?? ''}',
            ),
            providerMetadata: _providerMetadata(item['provider_metadata']),
          ),
    ];
  }

  Future<FundusRemoteCatalogPage> catalog(
    FundusRemoteServer server,
    String libraryId, {
    int since = 0,
    int limit = 1000,
    String? etag,
  }) async {
    final query = StringBuffer(
      '/v1/libraries/$libraryId/catalog?since=$since&limit=$limit',
    );
    if (etag != null && etag.isNotEmpty) {
      query.write('&etag=${Uri.encodeQueryComponent(etag)}');
    }
    final value = await _json(server, query.toString());
    final items = value['works'];
    final works = items is List
        ? items
              .whereType<Map>()
              .map(FundusRemoteWork.fromJson)
              .whereType<FundusRemoteWork>()
              .toList(growable: false)
        : const <FundusRemoteWork>[];
    final deleted = value['deleted'] is List
        ? (value['deleted'] as List).whereType<String>().toList(growable: false)
        : const <String>[];
    return FundusRemoteCatalogPage(
      works: works,
      deleted: deleted,
      nextCursor: value['next_cursor'] is int
          ? value['next_cursor'] as int
          : since,
      hasMore: value['has_more'] == true,
      etag: value['etag'] is String ? value['etag'] as String : null,
      notModified: value['not_modified'] == true,
    );
  }

  static Map<String, Object?> _providerMetadata(Object? value) => value is Map
      ? {
          for (final entry in value.entries)
            if (entry.key is String && entry.value != null)
              entry.key as String: entry.value,
        }
      : const {};

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

  Future<List<FundusRemoteCollection>> collections(
    FundusRemoteServer server,
    String libraryId,
  ) async {
    final value = await _json(server, '/v1/libraries/$libraryId/collections');
    final items = value['collections'];
    if (items is! List) return const [];
    return items
        .map(_collectionFromJson)
        .whereType<FundusRemoteCollection>()
        .toList(growable: false);
  }

  Future<FundusRemoteCollection> createCollection(
    FundusRemoteServer server, {
    required String libraryId,
    required String name,
    String? parentId,
    String kind = 'manual',
    Map<String, Object?>? rules,
    List<String> workIds = const [],
  }) => _writeCollection(
    server,
    '/v1/libraries/$libraryId/collections',
    method: 'POST',
    body: {
      'name': name,
      'parent_id': parentId,
      'kind': kind,
      'rules': rules,
      'work_ids': workIds,
    },
  );

  Future<FundusRemoteCollection> saveCollection(
    FundusRemoteServer server, {
    required String libraryId,
    required FundusRemoteCollection collection,
    required String name,
    String? parentId,
    String kind = 'manual',
    Map<String, Object?>? rules,
    List<String> workIds = const [],
  }) => _writeCollection(
    server,
    '/v1/libraries/$libraryId/collections/${Uri.encodeComponent(collection.id)}',
    method: 'PUT',
    body: {
      'name': name,
      'parent_id': parentId,
      'kind': kind,
      'rules': rules,
      'work_ids': workIds,
      'expected_revision': collection.revision,
    },
  );

  Future<void> deleteCollection(
    FundusRemoteServer server, {
    required String libraryId,
    required FundusRemoteCollection collection,
  }) async {
    final path =
        '/v1/libraries/$libraryId/collections/${Uri.encodeComponent(collection.id)}'
        '?expected_revision=${collection.revision}';
    try {
      await _request(
        server.baseUri.resolve(path),
        fingerprint: server.certificateFingerprint,
        token: server.token,
        method: 'DELETE',
      );
    } on FundusRemoteRequestException catch (error) {
      _throwCollectionConflict(error);
      rethrow;
    }
  }

  Future<FundusRemoteCollection> _writeCollection(
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
      final collection = _collectionFromJson(jsonDecode(utf8.decode(bytes)));
      if (collection == null) {
        throw const HttpException('Ungültige Sammlungs-Antwort.');
      }
      return collection;
    } on FundusRemoteRequestException catch (error) {
      _throwCollectionConflict(error);
      rethrow;
    }
  }

  static Never? _throwCollectionConflict(FundusRemoteRequestException error) {
    if (error.statusCode != HttpStatus.conflict) return null;
    try {
      final value = jsonDecode(error.responseBody);
      final collection = value is Map
          ? _collectionFromJson(value['collection'])
          : null;
      if (collection != null) throw FundusRemoteCollectionConflict(collection);
    } on FormatException {
      return null;
    }
    return null;
  }

  static FundusRemoteCollection? _collectionFromJson(Object? value) {
    if (value is! Map || value['id'] is! String || value['name'] is! String) {
      return null;
    }
    final rules = value['rules'];
    return FundusRemoteCollection(
      id: value['id'] as String,
      name: value['name'] as String,
      kind: value['kind'] is String ? value['kind'] as String : 'manual',
      parentId: value['parent_id'] is String
          ? value['parent_id'] as String
          : null,
      rules: rules is Map ? Map<String, Object?>.from(rules) : null,
      workIds: (value['work_ids'] as List? ?? const [])
          .whereType<String>()
          .toList(growable: false),
      revision: value['revision'] is int ? value['revision'] as int : 1,
      createdAt:
          DateTime.tryParse('${value['created_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt:
          DateTime.tryParse('${value['updated_at'] ?? ''}') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  Future<PlaybackSession?> playbackSession(
    FundusRemoteServer server,
    String libraryId,
  ) async {
    final value = await _json(
      server,
      '/v1/libraries/$libraryId/playback-session',
    );
    return _playbackSessionFromJson(value['session']);
  }

  Future<PlaybackSession> savePlaybackSession(
    FundusRemoteServer server, {
    required String libraryId,
    required PlaybackSession session,
    required String deviceId,
    required int expectedRevision,
  }) async {
    try {
      final bytes = await _request(
        server.baseUri.resolve('/v1/libraries/$libraryId/playback-session'),
        fingerprint: server.certificateFingerprint,
        token: server.token,
        method: 'PUT',
        body: jsonEncode({
          'expected_revision': expectedRevision,
          'device_id': deviceId,
          'playlist_id': session.playlistId,
          'playlist_revision': session.playlistRevision,
          'items': [for (final item in session.items) item.toJson()],
          'current_index': session.currentIndex,
          'current_position': session.currentPosition.toJson(),
          'repeat_mode': session.repeatMode.name,
          'shuffle_order': session.shuffleOrder,
        }),
      );
      final saved = _playbackSessionFromJson(jsonDecode(utf8.decode(bytes)));
      if (saved == null) {
        throw const HttpException('Ungültige Wiedergabesitzungs-Antwort.');
      }
      return saved;
    } on FundusRemoteRequestException catch (error) {
      if (error.statusCode == HttpStatus.conflict) {
        try {
          final value = jsonDecode(error.responseBody);
          final current = value is Map
              ? _playbackSessionFromJson(value['session'])
              : null;
          throw FundusRemotePlaybackSessionConflict(current);
        } on FormatException {
          // Der ursprüngliche HTTP-Fehler enthält keine auswertbare Sitzung.
        }
      }
      rethrow;
    }
  }

  static PlaybackSession? _playbackSessionFromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['items'] is! List ||
        value['current_index'] is! int ||
        value['current_position'] is! Map ||
        value['repeat_mode'] is! String ||
        value['shuffle_order'] is! List ||
        value['revision'] is! int) {
      return null;
    }
    try {
      final session = PlaybackSession(
        id: value['id'] as String,
        playlistId: value['playlist_id'] is String
            ? value['playlist_id'] as String
            : null,
        playlistRevision: value['playlist_revision'] is int
            ? value['playlist_revision'] as int
            : null,
        items: [
          for (final item in (value['items'] as List).whereType<Map>())
            PlaybackSessionItem(
              workId: item['work_id'] as String,
              fileIds: (item['file_ids'] as List).cast<String>(),
              position: item['position'] as int,
            ),
        ],
        currentIndex: value['current_index'] as int,
        currentPosition: MediaPosition.fromJson(
          (value['current_position'] as Map).cast<String, Object?>(),
        ),
        repeatMode: RepeatMode.values.firstWhere(
          (mode) => mode.name == value['repeat_mode'],
        ),
        shuffleOrder: (value['shuffle_order'] as List).cast<int>(),
        revision: value['revision'] as int,
        updatedAt: DateTime.tryParse('${value['updated_at'] ?? ''}'),
      );
      session.validate();
      return session;
    } catch (_) {
      return null;
    }
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
              size: item['size'] is int ? item['size'] as int : null,
              mimeType: item['mime_type'] as String?,
              duration: item['duration_seconds'] is num
                  ? Duration(
                      milliseconds: ((item['duration_seconds'] as num) * 1000)
                          .round(),
                    )
                  : null,
              audioMetadata: _audioMetadata(item['audio']),
              episode:
                  videoEpisodeFromJson(item['episode']) ??
                  parseVideoEpisode(item['title'] as String),
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

  static AudioTechnicalMetadata? _audioMetadata(Object? value) {
    if (value is! Map ||
        value['container'] is! String ||
        value['codec'] is! String) {
      return null;
    }
    return AudioTechnicalMetadata(
      container: value['container'] as String,
      codec: value['codec'] as String,
      profile: value['profile'] as String?,
      channels: value['channels'] as int?,
      sampleRateHz: value['sample_rate_hz'] as int?,
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
    final mediaPosition = _mediaPosition(position);
    final seconds = position['numeric_value'];
    final total = position['total'];
    return FundusRemoteProgress(
      fileId: progress['file_id'] is String
          ? progress['file_id'] as String
          : position['file_id'] is String
          ? position['file_id'] as String
          : null,
      position: Duration(
        milliseconds: seconds is num ? (seconds * 1000).round() : 0,
      ),
      duration: total is num
          ? Duration(milliseconds: (total * 1000).round())
          : null,
      mediaPosition: mediaPosition,
      finished: progress['finished'] == true,
      revision: progress['revision'] is int ? progress['revision'] as int : 0,
      deviceId: progress['device_id'] is String
          ? progress['device_id'] as String
          : null,
      deviceName: progress['device_name'] is String
          ? progress['device_name'] as String
          : null,
      updatedAt: DateTime.tryParse('${progress['updated_at'] ?? ''}'),
    );
  }

  Future<WorkAnnotations> annotations(
    FundusRemoteServer server,
    String libraryId,
    String workId,
  ) async => _annotationsFromJson(
    await _json(server, '/v1/libraries/$libraryId/annotations/$workId'),
    workId,
  );

  Future<WorkAnnotations> saveNote(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String markdown,
  }) async {
    final bytes = await _request(
      server.baseUri.resolve(
        '/v1/libraries/$libraryId/annotations/$workId/notes',
      ),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'POST',
      body: jsonEncode({'markdown': markdown}),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const HttpException('Ungültige Annotationen.');
    return _annotationsFromJson(value, workId);
  }

  Future<WorkAnnotations> saveTags(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required Iterable<String> tags,
  }) async {
    final bytes = await _request(
      server.baseUri.resolve(
        '/v1/libraries/$libraryId/annotations/$workId/tags',
      ),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'PUT',
      body: jsonEncode({'tags': tags.toList()}),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const HttpException('Ungültige Annotationen.');
    return _annotationsFromJson(value, workId);
  }

  Future<WorkAnnotations> saveBookmark(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    String? label,
    String? note,
  }) async => _saveAnnotation(
    server,
    path: '/v1/libraries/$libraryId/annotations/$workId/bookmarks',
    workId: workId,
    body: {
      'file_id': fileId,
      'position': position.toJson(),
      'label': label,
      'note': note,
    },
  );

  Future<WorkAnnotations> saveHighlight(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
    required String quote,
    required String color,
    String? note,
  }) async => _saveAnnotation(
    server,
    path: '/v1/libraries/$libraryId/annotations/$workId/highlights',
    workId: workId,
    body: {
      'file_id': fileId,
      'position': position.toJson(),
      'quote': quote,
      'color': color,
      'note': note,
    },
  );

  Future<WorkAnnotations> _saveAnnotation(
    FundusRemoteServer server, {
    required String path,
    required String workId,
    required Map<String, Object?> body,
  }) async {
    final bytes = await _request(
      server.baseUri.resolve(path),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'POST',
      body: jsonEncode(body),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const HttpException('Ungültige Annotationen.');
    return _annotationsFromJson(value, workId);
  }

  Future<WorkAnnotations> deleteAnnotation(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String annotationId,
    required bool highlight,
  }) async {
    final kind = highlight ? 'highlights' : 'bookmarks';
    final bytes = await _request(
      server.baseUri.resolve(
        '/v1/libraries/$libraryId/annotations/$workId/$kind/$annotationId',
      ),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'DELETE',
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map) throw const HttpException('Ungültige Annotationen.');
    return _annotationsFromJson(value, workId);
  }

  Future<Map<String, Object?>?> readerProfile(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String deviceKey,
    required String readerKind,
  }) async {
    final value = await _json(
      server,
      '/v1/libraries/$libraryId/reader-settings/$workId/$deviceKey/$readerKind',
    );
    final profile = value['profile'];
    return profile is Map ? Map<String, Object?>.from(profile) : null;
  }

  Future<void> saveReaderProfile(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String deviceKey,
    required String readerKind,
    required Map<String, Object?> profile,
  }) async {
    await _request(
      server.baseUri.resolve(
        '/v1/libraries/$libraryId/reader-settings/$workId/$deviceKey/$readerKind',
      ),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'PUT',
      body: jsonEncode({'profile': profile}),
    );
  }

  static WorkAnnotations _annotationsFromJson(Map value, String workId) {
    final notes = <LibraryNote>[];
    for (final item in (value['notes'] as List? ?? const []).whereType<Map>()) {
      if (item['id'] is! String || item['markdown'] is! String) continue;
      notes.add(
        LibraryNote(
          id: item['id'] as String,
          markdown: item['markdown'] as String,
          createdAt:
              DateTime.tryParse('${item['created_at'] ?? ''}') ??
              DateTime.fromMillisecondsSinceEpoch(0),
        ),
      );
    }
    final bookmarks = <LibraryBookmark>[];
    for (final item
        in (value['bookmarks'] as List? ?? const []).whereType<Map>()) {
      final id = item['id'];
      final position = item['position'];
      if (id is! String || position is! Map) continue;
      try {
        bookmarks.add(
          LibraryBookmark(
            id: id,
            workId: workId,
            fileId: item['file_id'] is String
                ? item['file_id'] as String
                : null,
            mediaPosition: MediaPosition.fromJson(
              Map<String, Object?>.from(position),
            ),
            label: item['label'] is String ? item['label'] as String : null,
            note: item['note'] is String ? item['note'] as String : null,
            createdAt:
                DateTime.tryParse('${item['created_at'] ?? ''}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      } on Object {
        // Ignore one malformed remote bookmark.
      }
    }
    final highlights = <LibraryHighlight>[];
    for (final item
        in (value['highlights'] as List? ?? const []).whereType<Map>()) {
      final id = item['id'];
      final position = item['position'];
      final quote = item['quote'];
      if (id is! String || position is! Map || quote is! String) continue;
      try {
        highlights.add(
          LibraryHighlight(
            id: id,
            workId: workId,
            fileId: item['file_id'] is String
                ? item['file_id'] as String
                : null,
            mediaPosition: MediaPosition.fromJson(
              Map<String, Object?>.from(position),
            ),
            quote: quote,
            color: item['color'] is String
                ? item['color'] as String
                : '#FFF176',
            note: item['note'] is String ? item['note'] as String : null,
            createdAt:
                DateTime.tryParse('${item['created_at'] ?? ''}') ??
                DateTime.fromMillisecondsSinceEpoch(0),
          ),
        );
      } on Object {
        // Ignore one malformed remote highlight.
      }
    }
    return WorkAnnotations(
      tags: (value['tags'] as List? ?? const []).whereType<String>().toList(),
      notes: notes,
      bookmarks: bookmarks,
      highlights: highlights,
    );
  }

  Future<List<FundusRemoteProgressRevision>> progressRevisions(
    FundusRemoteServer server,
    String libraryId,
    String workId,
  ) async {
    final value = await _json(
      server,
      '/v1/libraries/$libraryId/progress/$workId/revisions',
    );
    final revisions = value['revisions'];
    if (revisions is! List) return const [];
    return revisions
        .map(_progressRevisionFromJson)
        .whereType<FundusRemoteProgressRevision>()
        .toList(growable: false);
  }

  Future<FundusRemoteProgress> restoreProgressRevision(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required int revision,
    required String deviceId,
    required String operationId,
  }) async {
    final bytes = await _request(
      server.baseUri.resolve(
        '/v1/libraries/$libraryId/progress/$workId/revisions/$revision/restore',
      ),
      fingerprint: server.certificateFingerprint,
      token: server.token,
      method: 'POST',
      body: jsonEncode({'device_id': deviceId, 'operation_id': operationId}),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['position'] is! Map) {
      throw const HttpException('Ungültige Fortschrittsrevision.');
    }
    final position = value['position'] as Map;
    final mediaPosition = _mediaPosition(position);
    if (mediaPosition == null) {
      throw const HttpException('Ungültige Fortschrittsposition.');
    }
    final seconds = position['numeric_value'];
    final total = position['total'];
    return FundusRemoteProgress(
      fileId: value['file_id'] is String ? value['file_id'] as String : null,
      position: Duration(
        milliseconds: seconds is num ? (seconds * 1000).round() : 0,
      ),
      duration: total is num
          ? Duration(milliseconds: (total * 1000).round())
          : null,
      mediaPosition: mediaPosition,
      finished: value['finished'] == true,
      revision: value['revision'] is int ? value['revision'] as int : 0,
      deviceId: value['device_id'] is String
          ? value['device_id'] as String
          : null,
      deviceName: value['device_name'] is String
          ? value['device_name'] as String
          : null,
    );
  }

  static FundusRemoteProgressRevision? _progressRevisionFromJson(
    Object? value,
  ) {
    if (value is! Map ||
        value['position'] is! Map ||
        value['revision'] is! int ||
        value['device_id'] is! String ||
        value['device_name'] is! String) {
      return null;
    }
    final createdAt = DateTime.tryParse('${value['created_at'] ?? ''}');
    if (createdAt == null) return null;
    final position = value['position'] as Map;
    final mediaPosition = _mediaPosition(position);
    if (mediaPosition == null) return null;
    final seconds = position['numeric_value'];
    final total = position['total'];
    return FundusRemoteProgressRevision(
      fileId: value['file_id'] is String ? value['file_id'] as String : null,
      position: Duration(
        milliseconds: seconds is num ? (seconds * 1000).round() : 0,
      ),
      duration: total is num
          ? Duration(milliseconds: (total * 1000).round())
          : null,
      mediaPosition: mediaPosition,
      finished: value['finished'] == true,
      revision: value['revision'] as int,
      createdAt: createdAt,
      deviceId: value['device_id'] as String,
      deviceName: value['device_name'] as String,
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
    final total = positionValue is Map ? positionValue['total'] : null;
    return FundusRemoteProgress(
      fileId: value['file_id'] is String ? value['file_id'] as String : fileId,
      position: Duration(
        milliseconds: seconds is num ? (seconds * 1000).round() : 0,
      ),
      duration: total is num
          ? Duration(milliseconds: (total * 1000).round())
          : duration,
      mediaPosition: positionValue is Map
          ? _mediaPosition(positionValue)
          : null,
      finished: value['finished'] == true,
      revision: value['revision'] is int ? value['revision'] as int : 0,
      deviceId: value['device_id'] is String
          ? value['device_id'] as String
          : null,
      deviceName: value['device_name'] is String
          ? value['device_name'] as String
          : null,
    );
  }

  Future<FundusRemoteProgress> saveMediaProgress(
    FundusRemoteServer server, {
    required String libraryId,
    required String workId,
    required String fileId,
    required MediaPosition position,
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
        'position': position.toJson(),
        'finished': finished,
      }),
    );
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map || value['position'] is! Map) {
      throw const HttpException('Ungültige Fortschrittsantwort.');
    }
    final savedPosition = _mediaPosition(value['position'] as Map);
    if (savedPosition == null) {
      throw const HttpException('Ungültige Medienposition in der Antwort.');
    }
    final numeric = savedPosition.numericValue ?? 0;
    final total = savedPosition.total;
    return FundusRemoteProgress(
      fileId: value['file_id'] is String ? value['file_id'] as String : fileId,
      position: Duration(milliseconds: (numeric * 1000).round()),
      duration: total == null
          ? null
          : Duration(milliseconds: (total * 1000).round()),
      mediaPosition: savedPosition,
      finished: value['finished'] == true,
      revision: value['revision'] is int ? value['revision'] as int : 0,
      deviceId: value['device_id'] is String
          ? value['device_id'] as String
          : null,
      deviceName: value['device_name'] is String
          ? value['device_name'] as String
          : null,
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

  Future<FundusRemoteComicManifest> comicPages(
    FundusRemoteServer server, {
    required String libraryId,
    required String fileId,
  }) async {
    final value = await _json(
      server,
      '/v1/libraries/$libraryId/files/$fileId/comic/pages',
    );
    final items = value['pages'];
    if (value['file_id'] is! String || items is! List) {
      throw const HttpException('Ungültiges Comic-Seitenmanifest.');
    }
    return FundusRemoteComicManifest(
      fileId: value['file_id'] as String,
      pages: [
        for (final item in items.whereType<Map>())
          if (item['index'] is int &&
              item['id'] is String &&
              item['name'] is String &&
              item['size'] is int &&
              item['mime_type'] is String)
            FundusRemoteComicPage(
              index: item['index'] as int,
              id: item['id'] as String,
              name: item['name'] as String,
              size: item['size'] as int,
              mimeType: item['mime_type'] as String,
              width: item['width'] is int ? item['width'] as int : null,
              height: item['height'] is int ? item['height'] as int : null,
            ),
      ],
    );
  }

  Future<Uint8List> comicPage(
    FundusRemoteServer server, {
    required String libraryId,
    required String fileId,
    required int pageIndex,
  }) => _request(
    server.baseUri.resolve(
      '/v1/libraries/$libraryId/files/$fileId/comic/pages/$pageIndex',
    ),
    fingerprint: server.certificateFingerprint,
    token: server.token,
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
      final encoded = Uint8List.fromList(
        await stream.response
            .timeout(const Duration(seconds: 20))
            .expand((chunk) => chunk)
            .toList(),
      );
      final contentEncoding = stream.response.headers
          .value(HttpHeaders.contentEncodingHeader)
          ?.toLowerCase()
          .split(',')
          .map((value) => value.trim());
      if (contentEncoding?.contains('gzip') == true) {
        return Uint8List.fromList(gzip.decode(encoded));
      }
      return encoded;
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
    // We negotiate gzip for JSON responses and decode it explicitly below.
    // Dart's HttpClient otherwise transparently inflates the body while still
    // exposing the Content-Encoding header, which would make a second decode
    // fail on some Android and desktop runtimes.
    client.autoUncompress = false;
    client.connectionTimeout = const Duration(seconds: 4);
    client.badCertificateCallback = (certificate, host, port) =>
        _fingerprint(certificate) == fingerprint;
    try {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
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
        final encoded = await response
            .timeout(const Duration(seconds: 20))
            .expand((chunk) => chunk)
            .toList();
        final contentEncoding = response.headers
            .value(HttpHeaders.contentEncodingHeader)
            ?.toLowerCase()
            .split(',')
            .map((value) => value.trim());
        final bodyBytes = contentEncoding?.contains('gzip') == true
            ? gzip.decode(encoded)
            : encoded;
        final responseBody = utf8.decode(bodyBytes);
        throw FundusRemoteRequestException(
          response.statusCode,
          responseBody,
          requestUri: uri,
        );
      }
      return FundusRemoteStream(client, response);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }

  static String _fingerprint(X509Certificate certificate) =>
      sha256.convert(certificate.der).toString();

  static MediaPosition? _mediaPosition(Map value) {
    try {
      return MediaPosition.fromJson(Map<String, Object?>.from(value));
    } on Object {
      return null;
    }
  }
}
