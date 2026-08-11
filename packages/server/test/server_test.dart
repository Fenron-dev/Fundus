import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late FundusLibraryRegistry registry;
  late FundusServerHandler server;
  late FundusLibrary firstLibrary;
  late FundusLibrary secondLibrary;
  late LibraryWorkSummary work;
  late LibraryPlaybackTrack track;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('fundus-server-');
    firstLibrary = await _library(
      Directory('${temporary.path}/Hoerbuecher'),
      title: 'Der Server-Test',
      bytes: List.generate(10, (index) => index),
      withCover: true,
    );
    secondLibrary = await _library(
      Directory('${temporary.path}/Filme und mehr'),
      title: 'Zweites Werk',
      bytes: [10, 11, 12],
    );
    work = firstLibrary.listWorks().single;
    track = firstLibrary.playbackTracks(work.id).single;
    registry = FundusLibraryRegistry()
      ..register(firstLibrary, name: 'Hörbücher')
      ..register(secondLibrary, name: 'Filme und mehr');
    server = FundusServerHandler(
      token: 'secret',
      serverId: 'server-test',
      registry: registry,
    );
  });

  tearDown(() async {
    registry.close();
    await temporary.delete(recursive: true);
  });

  test('health is public without exposing library metadata', () async {
    final response = await server.handler(
      Request('GET', Uri.parse('http://localhost/v1/health')),
    );
    final body = await _json(response);
    expect(response.statusCode, 200);
    expect(body['server_id'], 'server-test');
    expect(body.containsKey('library_count'), isFalse);
  });

  test('API rejects missing token', () async {
    final response = await server.handler(
      Request('GET', Uri.parse('http://localhost/v1/libraries')),
    );
    expect(response.statusCode, 401);
  });

  test('reports sanitized request diagnostics', () async {
    FundusServerRequestEvent? observed;
    final observedServer = FundusServerHandler(
      token: 'secret',
      serverId: 'server-test',
      registry: registry,
      requestObserver: (event) => observed = event,
    );
    final response = await observedServer.handler(
      Request(
        'GET',
        Uri.parse('http://localhost/v1/libraries/private-id/works'),
        headers: {'authorization': 'Bearer secret'},
      ),
    );
    expect(response.statusCode, 404);
    expect(observed?.method, 'GET');
    expect(observed?.resource, 'works');
    expect(observed?.statusCode, 404);
  });

  test('pairs a device once and accepts its revocable token', () async {
    final authority = FundusPairingAuthority();
    final session = authority.begin(lifetime: const Duration(minutes: 1));
    final pairedServer = FundusServerHandler(
      token: 'local-only-secret',
      serverId: 'server-test',
      serverName: 'Wohnzimmer-PC',
      registry: registry,
      pairingAuthority: authority,
    );
    final claim = await pairedServer.handler(
      Request(
        'POST',
        Uri.parse('https://localhost/v1/pairing/claim'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'nonce': session.nonce,
          'pin': session.pin,
          'device_id': 'phone-1',
          'device_name': 'Telefon',
        }),
      ),
    );
    final claimBody = await _json(claim);
    final deviceToken = claimBody['token']! as String;
    expect(claim.statusCode, 200);
    expect(claimBody['server_name'], 'Wohnzimmer-PC');
    expect(authority.activeSession, isNull);
    expect(authority.devices.single.tokenHash, isNot(deviceToken));
    await authority.rename('phone-1', 'Privates Telefon');
    expect(authority.devices.single.name, 'Privates Telefon');

    final accepted = await pairedServer.handler(
      Request(
        'GET',
        Uri.parse('https://localhost/v1/libraries'),
        headers: {'authorization': 'Bearer $deviceToken'},
      ),
    );
    expect(accepted.statusCode, 200);

    await authority.revoke('phone-1');
    final revoked = await pairedServer.handler(
      Request(
        'GET',
        Uri.parse('https://localhost/v1/libraries'),
        headers: {'authorization': 'Bearer $deviceToken'},
      ),
    );
    expect(revoked.statusCode, 401);
  });

  test('locks pairing after five invalid attempts', () async {
    final authority = FundusPairingAuthority();
    final session = authority.begin();
    for (var attempt = 0; attempt < 5; attempt++) {
      await expectLater(
        authority.claim(
          nonce: session.nonce,
          pin: '000000' == session.pin ? '111111' : '000000',
          deviceId: 'phone-1',
          deviceName: 'Telefon',
        ),
        throwsA(isA<FundusPairingException>()),
      );
    }
    expect(authority.activeSession, isNull);
  });

  test('capabilities expose format versions and server features', () async {
    final response = await _get(server, '/v1/capabilities');
    final body = await _json(response);
    expect(response.statusCode, 200);
    expect(body['server_id'], 'server-test');
    expect(body['server_name'], 'Fundus');
    expect(body['library_format_version'], 1);
    expect(body['capabilities'], contains('multiple_libraries'));
    expect(body['capabilities'], contains('range_streaming'));
    expect(body['capabilities'], contains('chapters'));
    expect(body['capabilities'], contains('playlists'));
    expect(body['capabilities'], contains('playlist_revisions'));
  });

  test('lists multiple libraries without exposing local paths', () async {
    final response = await _get(server, '/v1/libraries');
    final source = await response.readAsString();
    final body = jsonDecode(source) as Map<String, Object?>;
    final libraries = body['libraries']! as List<dynamic>;
    expect(libraries, hasLength(2));
    expect(
      libraries.map((value) => (value as Map<String, dynamic>)['name']),
      containsAll(['Hörbücher', 'Filme und mehr']),
    );
    expect(source, isNot(contains(temporary.path)));
  });

  test('returns work details and opaque file IDs', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final response = await _get(
      server,
      '/v1/libraries/$libraryId/works/${work.id}',
    );
    final source = await response.readAsString();
    final body = jsonDecode(source) as Map<String, Object?>;
    final files = body['files']! as List<dynamic>;
    final chapters = body['chapters']! as List<dynamic>;
    expect(response.statusCode, 200);
    expect(body['title'], 'Der Server-Test');
    expect((files.single as Map<String, dynamic>)['id'], track.fileId);
    expect(chapters, hasLength(1));
    expect((chapters.single as Map<String, dynamic>)['file_id'], track.fileId);
    expect((chapters.single as Map<String, dynamic>)['position_seconds'], 0);
    expect(source, isNot(contains(temporary.path)));
    expect(source, isNot(contains(track.relativePath)));
  });

  test('streams byte ranges with ETag and no path parameter', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final response = await server.handler(
      Request(
        'GET',
        Uri.parse(
          'http://localhost/v1/libraries/$libraryId/files/${track.fileId}/content',
        ),
        headers: {'authorization': 'Bearer secret', 'range': 'bytes=2-4'},
      ),
    );
    final bytes = await response.read().expand((chunk) => chunk).toList();
    expect(response.statusCode, HttpStatus.partialContent);
    expect(bytes, [2, 3, 4]);
    expect(response.headers['content-range'], 'bytes 2-4/10');
    expect(response.headers['accept-ranges'], 'bytes');
    expect(response.headers['etag'], isNotEmpty);
  });

  test('rejects an unsatisfiable range', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final response = await server.handler(
      Request(
        'GET',
        Uri.parse(
          'http://localhost/v1/libraries/$libraryId/files/${track.fileId}/content',
        ),
        headers: {'authorization': 'Bearer secret', 'range': 'bytes=20-30'},
      ),
    );
    expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(response.headers['content-range'], 'bytes */10');
  });

  test('serves a work cover through its opaque work ID', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final response = await _get(
      server,
      '/v1/libraries/$libraryId/works/${work.id}/cover',
    );
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'image/jpeg');
    expect(await response.read().expand((chunk) => chunk).toList(), [
      255,
      216,
      255,
      217,
    ]);
  });

  test('progress update is idempotent by operation ID', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/progress/${work.id}';
    final payload = jsonEncode({
      'operation_id': 'client-operation-1',
      'device_id': 'phone-test',
      'file_id': track.fileId,
      'position_seconds': 42.5,
      'duration_seconds': 120,
    });
    final first = await _put(server, path, payload);
    final repeated = await _put(server, path, payload);
    final firstBody = await _json(first);
    final repeatedBody = await _json(repeated);
    expect(first.statusCode, 200);
    expect(firstBody['revision'], 1);
    expect(repeatedBody['revision'], 1);

    final loaded = await _get(server, path);
    final loadedBody = await _json(loaded);
    final progress = loadedBody['progress']! as Map<String, dynamic>;
    expect(progress['revision'], 1);
    expect(
      (progress['position']! as Map<String, dynamic>)['numeric_value'],
      42.5,
    );
  });

  test('syncs playlists with revision conflict protection', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/playlists';
    final createdResponse = await _post(
      server,
      path,
      jsonEncode({
        'name': 'Unterwegs',
        'media_type': 'audiobook',
        'work_ids': [work.id],
      }),
    );
    final created = await _json(createdResponse);
    expect(createdResponse.statusCode, HttpStatus.created);
    expect(created['revision'], 1);
    expect(created['work_ids'], [work.id]);
    final playlistId = created['id']! as String;

    final listed = await _json(await _get(server, path));
    expect(listed['playlists'], hasLength(1));

    final updatedResponse = await _put(
      server,
      '$path/$playlistId',
      jsonEncode({
        'name': 'Unterwegs aktualisiert',
        'media_type': 'audiobook',
        'work_ids': [work.id],
        'expected_revision': 1,
      }),
    );
    final updated = await _json(updatedResponse);
    expect(updated['revision'], 2);

    final conflictResponse = await _put(
      server,
      '$path/$playlistId',
      jsonEncode({
        'name': 'Veraltete Änderung',
        'media_type': 'audiobook',
        'work_ids': [work.id],
        'expected_revision': 1,
      }),
    );
    final conflict = await _json(conflictResponse);
    expect(conflictResponse.statusCode, HttpStatus.conflict);
    expect(conflict['error'], 'playlist_conflict');
    expect((conflict['playlist']! as Map<String, dynamic>)['revision'], 2);

    final deleteConflict = await _delete(
      server,
      '$path/$playlistId?expected_revision=1',
    );
    expect(deleteConflict.statusCode, HttpStatus.conflict);
    final deleted = await _delete(
      server,
      '$path/$playlistId?expected_revision=2',
    );
    expect(deleted.statusCode, HttpStatus.noContent);
    final afterDelete = await _json(await _get(server, path));
    expect(afterDelete['playlists'], isEmpty);
  });
}

Future<FundusLibrary> _library(
  Directory root, {
  required String title,
  required List<int> bytes,
  bool withCover = false,
}) async {
  final work = Directory('${root.path}/Audiobooks/Autor/Serie/01 - $title');
  await work.create(recursive: true);
  await File('${work.path}/01 - $title.mp3').writeAsBytes(bytes);
  if (withCover) {
    await File('${work.path}/cover.jpg').writeAsBytes([255, 216, 255, 217]);
  }
  final library = await FundusLibrary.create(root);
  await library.index().drain<void>();
  return library;
}

Future<Response> _get(FundusServerHandler server, String path) async =>
    await server.handler(
      Request(
        'GET',
        Uri.parse('http://localhost$path'),
        headers: {'authorization': 'Bearer secret'},
      ),
    );

Future<Response> _put(
  FundusServerHandler server,
  String path,
  String body,
) async => await server.handler(
  Request(
    'PUT',
    Uri.parse('http://localhost$path'),
    headers: {
      'authorization': 'Bearer secret',
      'content-type': 'application/json',
    },
    body: body,
  ),
);

Future<Response> _post(
  FundusServerHandler server,
  String path,
  String body,
) async => await server.handler(
  Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: {
      'authorization': 'Bearer secret',
      'content-type': 'application/json',
    },
    body: body,
  ),
);

Future<Response> _delete(FundusServerHandler server, String path) async =>
    await server.handler(
      Request(
        'DELETE',
        Uri.parse('http://localhost$path'),
        headers: {'authorization': 'Bearer secret'},
      ),
    );

Future<Map<String, Object?>> _json(Response response) async =>
    jsonDecode(await response.readAsString()) as Map<String, Object?>;
