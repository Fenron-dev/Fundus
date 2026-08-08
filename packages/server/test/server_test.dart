import 'dart:convert';

import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

void main() {
  final handler = FundusServerHandler(token: 'secret', serverId: 'server-test');

  test('health is public', () async {
    final response = await handler.handler(
      Request('GET', Uri.parse('http://localhost/health')),
    );
    expect(response.statusCode, 200);
  });

  test('API rejects missing token', () async {
    final response = await handler.handler(
      Request('GET', Uri.parse('http://localhost/api/v1/info')),
    );
    expect(response.statusCode, 401);
  });

  test('API info exposes format versions with bearer token', () async {
    final response = await handler.handler(
      Request(
        'GET',
        Uri.parse('http://localhost/api/v1/info'),
        headers: {'authorization': 'Bearer secret'},
      ),
    );
    final body =
        jsonDecode(await response.readAsString()) as Map<String, Object?>;
    expect(response.statusCode, 200);
    expect(body['server_id'], 'server-test');
    expect(body['library_format_version'], 1);
  });
}
