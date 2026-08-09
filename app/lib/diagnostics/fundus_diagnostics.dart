import 'dart:convert';
import 'dart:io';

final class FundusDiagnostics {
  FundusDiagnostics._();

  static final instance = FundusDiagnostics._();
  static const _maximumBytes = 2 * 1024 * 1024;

  File? _file;
  Future<void> _pending = Future.value();

  File? get file => _file;

  Future<void> configure(Directory libraryRoot) async {
    _file = File('${libraryRoot.path}/.library/diagnostics/fundus.log');
    await _file!.parent.create(recursive: true);
    await record('diagnostics.started', {'version': 1});
  }

  Future<void> record(String event, [Map<String, Object?> data = const {}]) {
    final target = _file;
    if (target == null) return Future.value();
    _pending = _pending
        .then((_) async {
          if (await target.exists() && await target.length() >= _maximumBytes) {
            final previous = File('${target.path}.1');
            if (await previous.exists()) await previous.delete();
            await target.rename(previous.path);
          }
          await target.writeAsString(
            '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), 'event': event, 'data': data})}\n',
            mode: FileMode.append,
            flush: true,
          );
        })
        .catchError((_) {});
    return _pending;
  }
}
