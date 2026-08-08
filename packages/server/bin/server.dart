import 'dart:io';

import 'package:fundus_server/fundus_server.dart';
import 'package:shelf/shelf_io.dart';

Future<void> main(List<String> arguments) async {
  final token = Platform.environment['FUNDUS_TOKEN'];
  if (token == null || token.isEmpty) {
    stderr.writeln('FUNDUS_TOKEN muss gesetzt sein.');
    exitCode = 64;
    return;
  }
  final serverId = Platform.environment['FUNDUS_SERVER_ID'] ?? 'fundus-dev';
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final handler = FundusServerHandler(token: token, serverId: serverId);
  final server = await serve(
    handler.handler,
    InternetAddress.loopbackIPv4,
    port,
  );
  stdout.writeln('Fundus lauscht lokal auf Port ${server.port}.');
}
