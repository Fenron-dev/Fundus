import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Device-local visibility policy for explicit adult content.
///
/// The setting is intentionally kept outside a library so reinstalling or
/// moving a portable library does not change the presentation policy of a
/// shared device. Server-side authorization remains a separate concern.
abstract final class HhhContentSettings {
  static const _fileName = 'hhh-content-settings.json';

  static Future<bool> enabled() async {
    try {
      final file = await _file();
      if (!await file.exists()) return false;
      final value = jsonDecode(await file.readAsString());
      return value is Map && value['show_hhh'] == true;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }

  static Future<void> setEnabled(bool value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(
      JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'show_hhh': value,
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  static Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, _fileName));
  }
}
