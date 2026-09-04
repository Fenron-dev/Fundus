import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Device-local visibility policy for explicit adult content.
///
/// The setting is intentionally kept outside a library so reinstalling or
/// moving a portable library does not change the presentation policy of a
/// shared device. Server-side authorization remains a separate concern.
enum HhhVisibilityMode {
  /// Do not expose HHH content in navigation, search, resume or statistics.
  hidden,

  /// Keep content hidden until the user unlocks it for the current session.
  protected,

  /// Show HHH content normally on this device.
  visible,
}

abstract final class HhhContentSettings {
  static const _fileName = 'hhh-content-settings.json';
  static const _sessionTimeout = Duration(minutes: 20);
  static DateTime? _unlockedUntil;

  static Future<HhhVisibilityMode> mode() async {
    final value = await _read();
    final raw = value['mode'];
    if (raw is String) {
      for (final mode in HhhVisibilityMode.values) {
        if (mode.name == raw) return mode;
      }
    }
    // Version 1 stored only show_hhh. Preserve that setting on upgrade.
    return value['show_hhh'] == true
        ? HhhVisibilityMode.visible
        : HhhVisibilityMode.hidden;
  }

  static Future<bool> isVisible() async {
    final selected = await mode();
    if (selected == HhhVisibilityMode.visible) return true;
    if (selected != HhhVisibilityMode.protected) return false;
    final until = _unlockedUntil;
    if (until == null || !until.isAfter(DateTime.now().toUtc())) {
      _unlockedUntil = null;
      return false;
    }
    return true;
  }

  static Future<bool> hasPin() async => (await _read())['pin_hash'] is String;

  static Future<void> setMode(HhhVisibilityMode value) async {
    final current = await _read();
    current['version'] = 2;
    current['mode'] = value.name;
    current['show_hhh'] = value == HhhVisibilityMode.visible;
    if (value != HhhVisibilityMode.protected) _unlockedUntil = null;
    await _write(current);
  }

  static Future<void> setPin(String pin) async {
    final normalized = pin.trim();
    if (normalized.length < 4) {
      throw ArgumentError.value(
        pin,
        'pin',
        'Mindestens 4 Zeichen erforderlich',
      );
    }
    final salt = _randomSalt();
    final current = await _read();
    current['version'] = 2;
    current['pin_salt'] = salt;
    current['pin_hash'] = _hash(normalized, salt);
    await _write(current);
  }

  static Future<bool> verifyPin(String pin) async {
    final current = await _read();
    final salt = current['pin_salt'];
    final expected = current['pin_hash'];
    if (salt is! String || expected is! String) return false;
    return _hash(pin.trim(), salt) == expected;
  }

  static Future<bool> unlock(String pin) async {
    if (!await verifyPin(pin)) return false;
    _unlockedUntil = DateTime.now().toUtc().add(_sessionTimeout);
    return true;
  }

  static void lock() => _unlockedUntil = null;

  static Future<bool> enabled() async {
    return isVisible();
  }

  static Future<void> setEnabled(bool value) async {
    await setMode(value ? HhhVisibilityMode.visible : HhhVisibilityMode.hidden);
  }

  static String _randomSalt() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    return base64Url.encode(bytes);
  }

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  static Future<Map<String, dynamic>> _read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return <String, dynamic>{};
      final value = jsonDecode(await file.readAsString());
      return value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
    } on FileSystemException {
      return <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  static Future<void> _write(Map<String, dynamic> value) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(
      JsonEncoder.withIndent('  ').convert(value),
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
