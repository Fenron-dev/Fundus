import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
      contentSensitivity: 'adult_explicit',
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
    expect(authority.devices.single.allowAdultExplicit, isFalse);
    await authority.setAdultExplicitAllowed('phone-1', true);
    expect(authority.devices.single.allowAdultExplicit, isTrue);

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

  test('authorization records recent paired-device activity', () async {
    final old = DateTime.utc(2026, 1, 1);
    List<FundusPairedDevice>? persisted;
    final authority = FundusPairingAuthority(
      devices: [
        FundusPairedDevice(
          id: 'tablet-1',
          name: 'Samsung Tablet',
          tokenHash: FundusPairingAuthority.tokenDigest('device-token'),
          pairedAt: old,
          lastSeenAt: old,
        ),
      ],
      onChanged: (devices) async => persisted = devices,
    );

    expect(authority.authorizeDevice('device-token'), 'tablet-1');
    await Future<void>.delayed(Duration.zero);

    expect(authority.devices.single.lastSeenAt!.isAfter(old), isTrue);
    expect(persisted?.single.id, 'tablet-1');
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
    expect(body['capabilities'], contains('comic_pages'));
    expect(body['capabilities'], contains('chapters'));
    expect(body['capabilities'], contains('playlists'));
    expect(body['capabilities'], contains('playlist_revisions'));
    expect(body['capabilities'], contains('playback_session_revisions'));
    expect(body['capabilities'], contains('progress_history'));
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

  test(
    'paired devices cannot browse HHH works without explicit permission',
    () async {
      const deviceToken = 'device-token';
      final authority = FundusPairingAuthority(
        devices: [
          FundusPairedDevice(
            id: 'phone-1',
            name: 'Telefon',
            tokenHash: FundusPairingAuthority.tokenDigest(deviceToken),
            pairedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      );
      final pairedServer = FundusServerHandler(
        token: 'secret',
        serverId: 'server-test',
        registry: registry,
        pairingAuthority: authority,
      );
      final libraryId = secondLibrary.manifest.libraryId;
      final workId = secondLibrary.listWorks().single.id;
      final request = (String path) => Request(
        'GET',
        Uri.parse('http://localhost$path'),
        headers: {'authorization': 'Bearer $deviceToken'},
      );

      final hidden = await pairedServer.handler(
        request('/v1/libraries/$libraryId/works'),
      );
      expect((await _json(hidden))['works'], isEmpty);
      final hiddenProgress = await pairedServer.handler(
        request('/v1/libraries/$libraryId/progress/$workId'),
      );
      expect(hiddenProgress.statusCode, 404);

      await authority.setAdultExplicitAllowed('phone-1', true);
      final visible = await pairedServer.handler(
        request('/v1/libraries/$libraryId/works'),
      );
      expect((await _json(visible))['works'], hasLength(1));
    },
  );

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
    final remoteFile = files.single as Map<String, dynamic>;
    expect(remoteFile['id'], track.fileId);
    expect((remoteFile['audio'] as Map<String, dynamic>)['codec'], 'MP3');
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

  test('serves a naturally sorted comic manifest and individual pages', () async {
    final comicLibrary = await _comicLibrary(
      Directory('${temporary.path}/Comics'),
    );
    final comicRegistry = FundusLibraryRegistry()
      ..register(comicLibrary, name: 'Comics');
    final comicServer = FundusServerHandler(
      token: 'secret',
      serverId: 'comic-server',
      registry: comicRegistry,
    );
    addTearDown(comicRegistry.close);
    final comicWork = comicLibrary.listWorks().single;
    final comicTrack = comicLibrary.playbackTracks(comicWork.id).single;
    final base =
        '/v1/libraries/${comicLibrary.manifest.libraryId}/files/${comicTrack.fileId}/comic/pages';

    final manifestResponse = await _get(comicServer, base);
    final source = await manifestResponse.readAsString();
    final manifest = jsonDecode(source) as Map<String, dynamic>;
    final pages = manifest['pages']! as List;
    expect(manifestResponse.statusCode, 200);
    expect(manifest['page_count'], 2);
    expect((pages.first as Map)['id'], 'pages/2.png');
    expect((pages.last as Map)['id'], 'pages/10.png');
    expect((pages.first as Map)['width'], 1);
    expect((pages.first as Map)['height'], 1);
    expect(source, isNot(contains(temporary.path)));

    final pageResponse = await _get(comicServer, '$base/0');
    final bytes = await pageResponse.read().expand((chunk) => chunk).toList();
    expect(pageResponse.statusCode, 200);
    expect(pageResponse.headers['content-type'], 'image/png');
    expect(pageResponse.headers['etag'], isNotEmpty);
    expect(bytes, _tinyPng);

    expect((await _get(comicServer, '$base/20')).statusCode, 404);
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

  test('stores media-neutral reader positions with anchors', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/progress/${work.id}';
    final response = await _put(
      server,
      path,
      jsonEncode({
        'operation_id': 'reader-position-1',
        'device_id': 'phone-test',
        'file_id': track.fileId,
        'position': {
          'schema_version': 2,
          'kind': 'imageIndex',
          'numeric_value': 14,
          'total': 32,
          'file_id': track.fileId,
          'chapter_id': 'Kapitel 12',
          'element_id': 'pages/014.webp',
          'scroll_offset': .42,
          'label': 'Kapitel 12 · Seite 14',
        },
      }),
    );
    expect(response.statusCode, 200);
    final body = await _json(response);
    final position = body['position']! as Map<String, dynamic>;
    expect(position['kind'], 'imageIndex');
    expect(position['numeric_value'], 14);
    expect(position['element_id'], 'pages/014.webp');
    expect(position['scroll_offset'], .42);

    final loaded = await _json(await _get(server, path));
    final progress = loaded['progress']! as Map<String, dynamic>;
    expect(
      (progress['position']! as Map<String, dynamic>)['chapter_id'],
      'Kapitel 12',
    );
  });

  test('syncs Markdown notes and favorite tags', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/annotations/${work.id}';
    final noteResponse = await _post(
      server,
      '$path/notes',
      jsonEncode({'markdown': '## Mobile Notiz'}),
    );
    expect(noteResponse.statusCode, 200);
    final tagsResponse = await _put(
      server,
      '$path/tags',
      jsonEncode({
        'tags': ['Favorit', 'Fantasy'],
      }),
    );
    expect(tagsResponse.statusCode, 200);
    final loaded = await _json(await _get(server, path));
    expect(loaded['tags'], containsAll(['Favorit', 'Fantasy']));
    expect((loaded['notes'] as List).single['markdown'], '## Mobile Notiz');
    expect(
      await File(
        '${firstLibrary.workDirectoryPath(work.id)}/_fundus/notes.md',
      ).readAsString(),
      contains('## Mobile Notiz'),
    );
    final profilePath =
        '/v1/libraries/$libraryId/reader-settings/${work.id}/android/epub';
    final profileResponse = await _put(
      server,
      profilePath,
      jsonEncode({
        'profile': {'font_size': 23.0, 'content_width': 640.0},
      }),
    );
    expect(profileResponse.statusCode, 200);
    final profile = await _json(await _get(server, profilePath));
    expect((profile['profile'] as Map)['font_size'], 23.0);
  });

  test('syncs semantic bookmarks and highlights', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/annotations/${work.id}';
    final position = {
      'schema_version': 2,
      'kind': 'epubCfi',
      'numeric_value': 42.0,
      'file_id': track.fileId,
      'chapter_id': 'chapter-4',
      'element_id': 'paragraph-7',
      'scroll_offset': .25,
      'key': 'chapter.xhtml',
    };
    final bookmarkResponse = await _post(
      server,
      '$path/bookmarks',
      jsonEncode({
        'file_id': track.fileId,
        'position': position,
        'label': 'Wichtige Stelle',
      }),
    );
    expect(bookmarkResponse.statusCode, 200);
    final highlightResponse = await _post(
      server,
      '$path/highlights',
      jsonEncode({
        'file_id': track.fileId,
        'position': position,
        'quote': 'Markierter Text',
        'color': '#FFF176',
      }),
    );
    expect(highlightResponse.statusCode, 200);

    final loaded = await _json(await _get(server, path));
    final bookmarks = loaded['bookmarks']! as List;
    final highlights = loaded['highlights']! as List;
    expect((bookmarks.single as Map)['label'], 'Wichtige Stelle');
    expect((highlights.single as Map)['quote'], 'Markierter Text');

    final bookmarkId = (bookmarks.single as Map)['id']! as String;
    final highlightId = (highlights.single as Map)['id']! as String;
    expect(
      (await _delete(server, '$path/bookmarks/$bookmarkId')).statusCode,
      200,
    );
    expect(
      (await _delete(server, '$path/highlights/$highlightId')).statusCode,
      200,
    );
    final deleted = await _json(await _get(server, path));
    expect(deleted['bookmarks'], isEmpty);
    expect(deleted['highlights'], isEmpty);
  });

  test('lists and restores progress history as a new revision', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/progress/${work.id}';
    for (final entry in [(id: 'one', seconds: 10), (id: 'two', seconds: 20)]) {
      await _put(
        server,
        path,
        jsonEncode({
          'operation_id': entry.id,
          'device_id': 'phone-test',
          'file_id': track.fileId,
          'position_seconds': entry.seconds,
        }),
      );
    }
    final history = await _json(await _get(server, '$path/revisions'));
    final revisions = history['revisions']! as List;
    expect(revisions, hasLength(2));
    expect((revisions.first as Map)['revision'], 2);
    expect((revisions.first as Map)['device_name'], 'Unbekanntes Gerät');

    final restored = await _post(
      server,
      '$path/revisions/1/restore',
      jsonEncode({'operation_id': 'restore-one', 'device_id': 'desktop-local'}),
    );
    final restoredBody = await _json(restored);
    expect(restoredBody['revision'], 3);
    expect(restoredBody['device_name'], 'Fundus');
    expect(
      (restoredBody['position']! as Map<String, dynamic>)['numeric_value'],
      10,
    );
    final repeated = await _post(
      server,
      '$path/revisions/1/restore',
      jsonEncode({'operation_id': 'restore-one', 'device_id': 'desktop-local'}),
    );
    expect((await _json(repeated))['revision'], 3);
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

  test('syncs a complete playback session with conflict protection', () async {
    final libraryId = firstLibrary.manifest.libraryId;
    final path = '/v1/libraries/$libraryId/playback-session';
    final payload = {
      'expected_revision': 0,
      'device_id': 'phone-test',
      'playlist_id': null,
      'playlist_revision': null,
      'items': [
        {
          'work_id': work.id,
          'file_ids': [track.fileId],
          'position': 0,
        },
      ],
      'current_index': 0,
      'current_position': {
        'kind': 'time',
        'numeric_value': 35.5,
        'file_id': track.fileId,
      },
      'repeat_mode': 'all',
      'shuffle_order': [0],
    };
    final savedResponse = await _put(server, path, jsonEncode(payload));
    final saved = await _json(savedResponse);
    expect(savedResponse.statusCode, 200);
    expect(saved['revision'], 1);
    expect(saved['repeat_mode'], 'all');
    expect(saved['shuffle_order'], [0]);

    final loaded = await _json(await _get(server, path));
    final session = loaded['session']! as Map<String, dynamic>;
    expect(session['current_index'], 0);
    expect(
      (session['current_position']! as Map<String, dynamic>)['numeric_value'],
      35.5,
    );

    final conflictResponse = await _put(server, path, jsonEncode(payload));
    final conflict = await _json(conflictResponse);
    expect(conflictResponse.statusCode, HttpStatus.conflict);
    expect(conflict['error'], 'playback_session_conflict');
    expect((conflict['session']! as Map<String, dynamic>)['revision'], 1);

    final updatedResponse = await _put(
      server,
      path,
      jsonEncode({...payload, 'expected_revision': 1}),
    );
    expect((await _json(updatedResponse))['revision'], 2);
  });
}

Future<FundusLibrary> _library(
  Directory root, {
  required String title,
  required List<int> bytes,
  bool withCover = false,
  String? contentSensitivity,
}) async {
  final work = Directory('${root.path}/Audiobooks/Autor/Serie/01 - $title');
  await work.create(recursive: true);
  await File('${work.path}/01 - $title.mp3').writeAsBytes(bytes);
  if (withCover) {
    await File('${work.path}/cover.jpg').writeAsBytes([255, 216, 255, 217]);
  }
  final library = await FundusLibrary.create(root);
  await library.index().drain<void>();
  if (contentSensitivity != null) {
    final indexed = library.listWorks().single;
    await library.updateWorkMetadata(
      workId: indexed.id,
      title: indexed.title,
      authors: indexed.authors,
      subtitle: indexed.subtitle,
      series: indexed.series,
      seriesSequence: indexed.seriesSequence,
      narrators: indexed.narrators,
      language: indexed.language,
      description: indexed.description,
      publisher: indexed.publisher,
      publishedYear: indexed.publishedYear,
      contentSensitivity: contentSensitivity,
    );
  }
  return library;
}

Future<FundusLibrary> _comicLibrary(Directory root) async {
  final work = Directory('${root.path}/Manga/Serie');
  await work.create(recursive: true);
  final archive = Archive()
    ..addFile(ArchiveFile.bytes('pages/10.png', _tinyPng))
    ..addFile(ArchiveFile.bytes('pages/2.png', _tinyPng));
  await File(
    '${work.path}/Kapitel 1.cbz',
  ).writeAsBytes(ZipEncoder().encode(archive));
  final library = await FundusLibrary.create(root);
  await library.index().drain<void>();
  return library;
}

final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

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
