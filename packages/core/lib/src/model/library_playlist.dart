enum LibraryPlaylistKind { manual, smart, series }

final class LibraryPlaylist {
  const LibraryPlaylist({
    required this.id,
    required this.name,
    required this.kind,
    required this.workIds,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final LibraryPlaylistKind kind;
  final List<String> workIds;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
}
