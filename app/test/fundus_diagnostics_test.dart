import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/diagnostics/fundus_diagnostics.dart';

void main() {
  test(
    'writes structured diagnostics without an absolute library path',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-diagnostics-');
      addTearDown(() => root.delete(recursive: true));

      await FundusDiagnostics.instance.configure(root);
      await FundusDiagnostics.instance.record('playback.test', {
        'work_id': 'work-1',
        'position_ms': 42000,
      });

      final lines = await FundusDiagnostics.instance.file!.readAsLines();
      final entry = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(entry['event'], 'playback.test');
      expect((entry['data'] as Map)['position_ms'], 42000);
      expect(lines.join('\n'), isNot(contains(root.path)));
    },
  );
}
