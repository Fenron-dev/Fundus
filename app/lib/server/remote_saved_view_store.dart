import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final class RemoteSavedViewStore {
  const RemoteSavedViewStore({File? file}) : _configuredFile = file;

  final File? _configuredFile;

  Future<File> _file() async =>
      _configuredFile ??
      File(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'remote_saved_views.json',
        ),
      );

  Future<List<LibrarySavedView>> load(String serverId, String libraryId) async {
    final records = await _read();
    final views = <LibrarySavedView>[];
    for (final record in records) {
      if (record['server_id'] != serverId ||
          record['library_id'] != libraryId) {
        continue;
      }
      final view = LibrarySavedView.fromJson(record['view']);
      if (view != null) views.add(view);
    }
    views.sort(
      (left, right) =>
          left.name.toLowerCase().compareTo(right.name.toLowerCase()),
    );
    return views;
  }

  Future<List<LibrarySavedView>> save(
    String serverId,
    String libraryId,
    String name,
    LibraryWorkQuery query,
  ) async {
    final records = await _read();
    final current = await load(serverId, libraryId);
    final normalized = name.trim();
    final previous = current
        .where((view) => view.name.toLowerCase() == normalized.toLowerCase())
        .firstOrNull;
    final view = LibrarySavedView(
      id: previous?.id ?? FundusId.generate(),
      name: normalized,
      query: query,
      updatedAt: DateTime.now().toUtc(),
    );
    records.removeWhere(
      (record) =>
          record['server_id'] == serverId &&
          record['library_id'] == libraryId &&
          (record['view'] as Map?)?['id'] == view.id,
    );
    records.add({
      'server_id': serverId,
      'library_id': libraryId,
      'view': view.toJson(),
    });
    await _write(records);
    return load(serverId, libraryId);
  }

  Future<List<LibrarySavedView>> delete(
    String serverId,
    String libraryId,
    String viewId,
  ) async {
    final records = await _read();
    records.removeWhere(
      (record) =>
          record['server_id'] == serverId &&
          record['library_id'] == libraryId &&
          (record['view'] as Map?)?['id'] == viewId,
    );
    await _write(records);
    return load(serverId, libraryId);
  }

  Future<List<Map<String, Object?>>> _read() async {
    final file = await _file();
    if (!await file.exists()) return [];
    try {
      final value = jsonDecode(await file.readAsString());
      return value is List
          ? value
                .whereType<Map>()
                .map((item) => Map<String, Object?>.from(item))
                .toList()
          : [];
    } on FileSystemException {
      return [];
    } on FormatException {
      return [];
    }
  }

  Future<void> _write(List<Map<String, Object?>> records) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(records)}\n',
      flush: true,
    );
  }
}
