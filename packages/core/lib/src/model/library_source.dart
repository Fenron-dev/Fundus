/// Origin of a catalog entry. A source is a vault on this device or a paired
/// peer; availability is deliberately kept separate so one library view can
/// show local, streamed, offline and unreachable content together.
enum LibrarySourceKind { vault, peer }

enum LibrarySourceAvailability {
  unknown,
  available,
  offline,
  unreachable,
  readOnly,
}

final class LibrarySource {
  const LibrarySource({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.libraryId,
    this.vaultPath,
    this.baseUrl,
    this.certificatePin,
    this.syncCursor = 0,
    this.availability = LibrarySourceAvailability.unknown,
    this.lastSeenAt,
  });

  final String id;
  final LibrarySourceKind kind;
  final String displayName;
  final String libraryId;
  final String? vaultPath;
  final String? baseUrl;
  final String? certificatePin;
  final int syncCursor;
  final LibrarySourceAvailability availability;
  final DateTime? lastSeenAt;

  LibrarySource copyWith({
    String? displayName,
    String? vaultPath,
    String? baseUrl,
    String? certificatePin,
    int? syncCursor,
    LibrarySourceAvailability? availability,
    DateTime? lastSeenAt,
  }) => LibrarySource(
    id: id,
    kind: kind,
    displayName: displayName ?? this.displayName,
    libraryId: libraryId,
    vaultPath: vaultPath ?? this.vaultPath,
    baseUrl: baseUrl ?? this.baseUrl,
    certificatePin: certificatePin ?? this.certificatePin,
    syncCursor: syncCursor ?? this.syncCursor,
    availability: availability ?? this.availability,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'display_name': displayName,
    'library_id': libraryId,
    if (vaultPath != null) 'vault_path': vaultPath,
    if (baseUrl != null) 'base_url': baseUrl,
    if (certificatePin != null) 'certificate_pin': certificatePin,
    'sync_cursor': syncCursor,
    'availability': availability.name,
    if (lastSeenAt != null)
      'last_seen_at': lastSeenAt!.toUtc().toIso8601String(),
  };

  static LibrarySource? fromJson(Object? value) {
    if (value is! Map) return null;
    final id = value['id'];
    final kind = value['kind'];
    final displayName = value['display_name'];
    final libraryId = value['library_id'];
    if (id is! String ||
        id.trim().isEmpty ||
        kind is! String ||
        displayName is! String ||
        libraryId is! String ||
        libraryId.trim().isEmpty) {
      return null;
    }
    final parsedKind = LibrarySourceKind.values
        .where((item) => item.name == kind)
        .firstOrNull;
    if (parsedKind == null) return null;
    final availabilityName = value['availability'];
    final parsedAvailability = LibrarySourceAvailability.values
        .where((item) => item.name == availabilityName)
        .firstOrNull;
    return LibrarySource(
      id: id,
      kind: parsedKind,
      displayName: displayName,
      libraryId: libraryId,
      vaultPath: value['vault_path'] is String
          ? value['vault_path'] as String
          : null,
      baseUrl: value['base_url'] is String ? value['base_url'] as String : null,
      certificatePin: value['certificate_pin'] is String
          ? value['certificate_pin'] as String
          : null,
      syncCursor: value['sync_cursor'] is int ? value['sync_cursor'] as int : 0,
      availability: parsedAvailability ?? LibrarySourceAvailability.unknown,
      lastSeenAt: DateTime.tryParse('${value['last_seen_at'] ?? ''}'),
    );
  }
}
