import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'fundus_remote_client.dart';

/// Small portable cache for remote work summaries.
///
/// The cache is metadata only: media bytes, credentials and absolute paths are
/// never stored here. Keeping it outside the vault makes the normal library
/// usable while a peer is asleep or temporarily unreachable.
final class FundusRemoteCatalogSnapshot {
  const FundusRemoteCatalogSnapshot({
    required this.serverId,
    required this.libraryId,
    required this.serverName,
    required this.libraryName,
    required this.works,
    required this.fetchedAt,
  });

  final String serverId;
  final String libraryId;
  final String serverName;
  final String libraryName;
  final List<FundusRemoteWork> works;
  final DateTime fetchedAt;

  String get key => '$serverId\u0000$libraryId';

  Map<String, Object?> toJson() => {
    'server_id': serverId,
    'library_id': libraryId,
    'server_name': serverName,
    'library_name': libraryName,
    'fetched_at': fetchedAt.toUtc().toIso8601String(),
    'works': works.map((work) => work.toJson()).toList(growable: false),
  };

  static FundusRemoteCatalogSnapshot? fromJson(Object? value) {
    if (value is! Map ||
        value['server_id'] is! String ||
        value['library_id'] is! String ||
        value['server_name'] is! String ||
        value['library_name'] is! String ||
        value['works'] is! List) {
      return null;
    }
    final fetchedAt = DateTime.tryParse('${value['fetched_at'] ?? ''}');
    if (fetchedAt == null) return null;
    return FundusRemoteCatalogSnapshot(
      serverId: value['server_id'] as String,
      libraryId: value['library_id'] as String,
      serverName: value['server_name'] as String,
      libraryName: value['library_name'] as String,
      works: (value['works'] as List)
          .map(FundusRemoteWork.fromJson)
          .whereType<FundusRemoteWork>()
          .toList(growable: false),
      fetchedAt: fetchedAt.toLocal(),
    );
  }
}

final class FundusRemoteCatalogStore {
  const FundusRemoteCatalogStore({this.file});

  final File? file;

  Future<File> _resolvedFile() async {
    if (file != null) return file!;
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, 'remote-catalog.json'));
  }

  Future<List<FundusRemoteCatalogSnapshot>> load() async {
    final target = await _resolvedFile();
    if (!await target.exists()) return const [];
    try {
      final decoded = jsonDecode(await target.readAsString());
      if (decoded is! List) return const [];
      return decoded
          .map(FundusRemoteCatalogSnapshot.fromJson)
          .whereType<FundusRemoteCatalogSnapshot>()
          .toList(growable: false);
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  Future<void> save(Iterable<FundusRemoteCatalogSnapshot> snapshots) async {
    final target = await _resolvedFile();
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.part');
    await temporary.writeAsString(
      jsonEncode(snapshots.map((snapshot) => snapshot.toJson()).toList()),
      flush: true,
    );
    await temporary.rename(target.path);
  }
}
