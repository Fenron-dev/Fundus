import 'dart:convert';

import 'package:fundus_core/fundus_core.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

final class FundusServerHandler {
  FundusServerHandler({required this.token, required this.serverId});

  final String token;
  final String serverId;

  Handler get handler {
    final router = Router()
      ..get('/health', _health)
      ..get('/api/v1/info', _info);
    return Pipeline()
        .addMiddleware(_authentication())
        .addMiddleware(_jsonErrors())
        .addHandler(router.call);
  }

  Response _health(Request request) =>
      _json({'status': 'ok', 'server_id': serverId});

  Response _info(Request request) => _json({
    'server_id': serverId,
    'api_version': 1,
    'library_format_version': LibraryManifest.currentFormatVersion,
    'min_reader_version': LibraryManifest.currentReaderVersion,
  });

  Middleware _authentication() {
    return (inner) {
      return (request) {
        if (request.url.path == 'health') return inner(request);
        final authorization = request.headers['authorization'];
        if (authorization != 'Bearer $token') {
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

  static Response _json(Object body, {int statusCode = 200}) {
    return Response(
      statusCode,
      body: jsonEncode(body),
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }
}
