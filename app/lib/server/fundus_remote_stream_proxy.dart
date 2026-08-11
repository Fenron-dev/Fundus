import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'fundus_remote_client.dart';

/// Keeps the remote TLS token and certificate handling inside Dart while the
/// native media engine only sees an unguessable loopback URL.
final class FundusRemoteStreamProxy {
  FundusRemoteStreamProxy._({
    required this.server,
    required this.libraryId,
    required this.workId,
    required this.tracks,
    required this.client,
    required HttpServer httpServer,
    required String capability,
  }) : _httpServer = httpServer,
       _capability = capability;

  final FundusRemoteServer server;
  final String libraryId;
  final String workId;
  final List<FundusRemoteTrack> tracks;
  final FundusRemoteClient client;
  final HttpServer _httpServer;
  final String _capability;
  StreamSubscription<HttpRequest>? _subscription;

  static Future<FundusRemoteStreamProxy> start({
    required FundusRemoteServer server,
    required String libraryId,
    required String workId,
    required List<FundusRemoteTrack> tracks,
    FundusRemoteClient client = const FundusRemoteClient(),
  }) async {
    final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = FundusRemoteStreamProxy._(
      server: server,
      libraryId: libraryId,
      workId: workId,
      tracks: tracks,
      client: client,
      httpServer: httpServer,
      capability: _randomValue(24),
    );
    proxy._subscription = httpServer.listen(proxy._handle);
    return proxy;
  }

  List<Uri> get urls => [
    for (var index = 0; index < tracks.length; index++)
      Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _httpServer.port,
        path: '/$_capability/$index${_extension(tracks[index].title)}',
      ),
  ];

  Uri get coverUrl => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _httpServer.port,
    path: '/$_capability/cover',
  );

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _httpServer.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    final segments = request.uri.pathSegments;
    if ((request.method != 'GET' && request.method != 'HEAD') ||
        segments.length != 2 ||
        segments.first != _capability) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (segments.last == 'cover') {
      await _handleCover(request);
      return;
    }
    final index = int.tryParse(segments.last.split('.').first);
    if (index == null || index < 0 || index >= tracks.length) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    FundusRemoteStream? remote;
    var forwardingStarted = false;
    try {
      remote = await client.openContent(
        server,
        libraryId: libraryId,
        fileId: tracks[index].id,
        range: request.headers.value(HttpHeaders.rangeHeader),
      );
      response.statusCode = remote.response.statusCode;
      for (final name in const [
        HttpHeaders.contentTypeHeader,
        HttpHeaders.contentLengthHeader,
        HttpHeaders.acceptRangesHeader,
        HttpHeaders.contentRangeHeader,
        HttpHeaders.etagHeader,
        HttpHeaders.lastModifiedHeader,
      ]) {
        final value = remote.response.headers.value(name);
        if (value != null) response.headers.set(name, value);
      }
      forwardingStarted = true;
      if (request.method == 'HEAD') {
        await remote.response.drain<void>();
        await response.close();
      } else {
        await remote.response.pipe(response);
      }
    } catch (_) {
      if (!forwardingStarted) {
        response.statusCode = HttpStatus.badGateway;
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode({'error': 'remote_stream_unavailable'}));
      }
      try {
        await response.close();
      } on HttpException {
        // The media engine may have closed a failed range request already.
      }
    } finally {
      remote?.close();
    }
  }

  Future<void> _handleCover(HttpRequest request) async {
    final response = request.response;
    try {
      final bytes = await client.cover(server, libraryId, workId);
      response.headers.contentType = ContentType('image', 'jpeg');
      response.headers.contentLength = bytes.length;
      if (request.method == 'GET') response.add(bytes);
    } catch (_) {
      response.statusCode = HttpStatus.badGateway;
    }
    await response.close();
  }

  static String _extension(String title) {
    final dot = title.lastIndexOf('.');
    if (dot < 0) return '';
    final value = title.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]{1,5}$').hasMatch(value) ? value : '';
  }

  static String _randomValue(int count) {
    final random = Random.secure();
    final bytes = List<int>.generate(count, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}
