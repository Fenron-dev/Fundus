import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
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
  final registry = FundusLibraryRegistry();
  for (final path in arguments) {
    final library = await FundusLibrary.open(Directory(path));
    final segments = library.root.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList();
    registry.register(
      library,
      name: segments.isEmpty ? 'Fundus' : segments.last,
    );
  }
  final handler = FundusServerHandler(
    token: token,
    serverId: serverId,
    registry: registry,
  );
  final server = await serve(
    handler.handler,
    InternetAddress.loopbackIPv4,
    port,
  );
  stdout.writeln('Fundus lauscht lokal auf Port ${server.port}.');
}
