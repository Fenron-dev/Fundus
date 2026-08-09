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
  });

  final Uri baseUri;
  final String serverId;
  final String certificateFingerprint;
  final String nonce;
  final String pin;
  final DateTime expiresAt;

  FundusPairingInvitation withPin(String value) => FundusPairingInvitation(
    baseUri: baseUri,
    serverId: serverId,
    certificateFingerprint: certificateFingerprint,
    nonce: nonce,
    pin: value,
    expiresAt: expiresAt,
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
  });

  final String id;
  final String name;
  final Uri baseUri;
  final String certificateFingerprint;
  final String token;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'base_url': baseUri.toString(),
    'certificate_sha256': certificateFingerprint,
    'token': token,
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

final class FundusRemoteWork {
  const FundusRemoteWork({
    required this.id,
    required this.title,
    required this.authors,
    required this.hasCover,
    this.series,
    this.seriesSequence,
    this.description,
  });

  final String id;
  final String title;
  final List<String> authors;
  final bool hasCover;
  final String? series;
  final num? seriesSequence;
  final String? description;
}

final class FundusRemoteServerStore {
  FundusRemoteServerStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const _serversKey = 'fundus.remote_servers.v1';
  static const _deviceIdKey = 'fundus.device_id.v1';
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

  static String _randomValue(int count) {
    final random = Random.secure();
    final bytes = List<int>.generate(count, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

final class FundusRemoteClient {
  const FundusRemoteClient();

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
    return FundusRemoteServer(
      id: invitation.serverId,
      name: 'Fundus ${invitation.baseUri.host}',
      baseUri: invitation.baseUri,
      certificateFingerprint: invitation.certificateFingerprint,
      token: value['token'] as String,
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
            series: item['series'] is String ? item['series'] as String : null,
            seriesSequence: item['series_sequence'] is num
                ? item['series_sequence'] as num
                : null,
            description: item['description'] is String
                ? item['description'] as String
                : null,
          ),
    ];
  }

  Future<Uint8List> cover(
    FundusRemoteServer server,
    String libraryId,
    String workId,
  ) => _request(
    server.baseUri.resolve('/v1/libraries/$libraryId/works/$workId/cover'),
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
    final client = HttpClient();
    client.badCertificateCallback = (certificate, host, port) =>
        _fingerprint(certificate) == fingerprint;
    try {
      final request = await client.openUrl(method, uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
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
      final bytes = Uint8List.fromList(
        await response.expand((chunk) => chunk).toList(),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Serverfehler ${response.statusCode}.');
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  static String _fingerprint(X509Certificate certificate) =>
      sha256.convert(certificate.der).toString();
}
