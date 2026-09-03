/// A user-facing virtual collection of works.
///
/// Collections deliberately live beside the catalog rather than changing the
/// on-disk media layout. This keeps them portable and lets one work belong to
/// several collections at once.
final class LibraryCollection {
  const LibraryCollection({
    required this.id,
    required this.name,
    this.parentId,
    this.kind = 'manual',
    this.rules,
    required this.workIds,
    required this.createdAt,
    this.revision = 1,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? createdAt;

  final String id;
  final String name;
  final String? parentId;
  final String kind;
  final Map<String, Object?>? rules;
  final List<String> workIds;
  final DateTime createdAt;
  final int revision;
  final DateTime updatedAt;

  bool get isSmart => kind == 'smart';
}
