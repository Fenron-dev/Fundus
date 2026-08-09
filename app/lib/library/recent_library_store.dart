import 'dart:convert';
import 'dart:io';

final class RecentLibraryEntry {
  const RecentLibraryEntry({required this.path, required this.lastOpenedAt});

  final String path;
  final DateTime lastOpenedAt;

  String get name {
    final segments = path
        .split(Platform.pathSeparator)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return segments.isEmpty ? path : segments.last;
  }

  bool get available =>
      Directory(path).existsSync() &&
      File(
        '$path${Platform.pathSeparator}.library'
        '${Platform.pathSeparator}version.json',
      ).existsSync();

  Map<String, Object?> toJson() => {
    'path': path,
    'last_opened_at': lastOpenedAt.toUtc().toIso8601String(),
  };
}

final class RecentLibraryStore {
  RecentLibraryStore(this.file);

  factory RecentLibraryStore.platformDefault() {
    final environment = Platform.environment;
    late final String base;
    if (Platform.isMacOS) {
      base =
          '${environment['HOME'] ?? Directory.current.path}'
          '${Platform.pathSeparator}Library${Platform.pathSeparator}'
          'Application Support';
    } else if (Platform.isWindows) {
      base = environment['APPDATA'] ?? Directory.current.path;
    } else {
      base =
          environment['XDG_CONFIG_HOME'] ??
          '${environment['HOME'] ?? Directory.current.path}'
              '${Platform.pathSeparator}.config';
    }
    return RecentLibraryStore(
      File(
        '$base${Platform.pathSeparator}Fundus'
        '${Platform.pathSeparator}recent_libraries.json',
      ),
    );
  }

  final File file;

  Future<List<RecentLibraryEntry>> load() async {
    if (!await file.exists()) return const [];
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! List) return const [];
      final entries = <RecentLibraryEntry>[];
      for (final item in value.whereType<Map>()) {
        final path = item['path'];
        final timestamp = item['last_opened_at'];
        if (path is! String || timestamp is! String) continue;
        final lastOpenedAt = DateTime.tryParse(timestamp);
        if (lastOpenedAt == null) continue;
        entries.add(
          RecentLibraryEntry(path: path, lastOpenedAt: lastOpenedAt.toLocal()),
        );
      }
      entries.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
      return entries.take(10).toList(growable: false);
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }

  Future<List<RecentLibraryEntry>> remember(
    String path,
    List<RecentLibraryEntry> current,
  ) async {
    final normalized = Directory(path).absolute.path;
    final entries = [
      RecentLibraryEntry(path: normalized, lastOpenedAt: DateTime.now()),
      ...current.where((entry) => entry.path != normalized),
    ].take(10).toList(growable: false);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert(entries.map((entry) => entry.toJson()).toList()),
      flush: true,
    );
    return entries;
  }
}
