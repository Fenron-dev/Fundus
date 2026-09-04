import 'package:fundus_core/fundus_core.dart';

/// Describes where a catalog entry is currently served from.
///
/// The origin is deliberately metadata on an entry, never a separate view
/// or player path. This keeps local, remote and offline works in one catalog.
enum FundusCatalogSourceKind { local, remote, offline }

enum FundusCatalogAvailability { available, offline, unreachable, missing }

final class FundusCatalogSource {
  const FundusCatalogSource({
    required this.id,
    required this.kind,
    required this.displayName,
    this.libraryName,
    this.availability = FundusCatalogAvailability.available,
  });

  final String id;
  final FundusCatalogSourceKind kind;
  final String displayName;
  final String? libraryName;
  final FundusCatalogAvailability availability;

  /// Converts the persisted Core source representation into the UI-neutral
  /// catalog source.  The conversion deliberately keeps availability as
  /// metadata; callers do not need a separate local/remote widget branch.
  factory FundusCatalogSource.fromLibrarySource(LibrarySource source) {
    final kind = switch (source.kind) {
      LibrarySourceKind.vault => FundusCatalogSourceKind.local,
      LibrarySourceKind.peer => FundusCatalogSourceKind.remote,
    };
    final availability = switch (source.availability) {
      LibrarySourceAvailability.available =>
        FundusCatalogAvailability.available,
      LibrarySourceAvailability.offline => FundusCatalogAvailability.offline,
      LibrarySourceAvailability.unreachable =>
        FundusCatalogAvailability.unreachable,
      LibrarySourceAvailability.readOnly => FundusCatalogAvailability.available,
      LibrarySourceAvailability.unknown => FundusCatalogAvailability.missing,
    };
    return FundusCatalogSource(
      id: source.id,
      kind: kind,
      displayName: source.displayName,
      libraryName: source.kind == LibrarySourceKind.peer
          ? source.displayName
          : null,
      availability: availability,
    );
  }

  bool get isLocal => kind == FundusCatalogSourceKind.local;
  bool get isRemote => kind == FundusCatalogSourceKind.remote;

  /// Offline is availability of a peer source, not a third catalog branch.
  /// The legacy enum value is still understood when reading older caches.
  bool get isOffline =>
      availability == FundusCatalogAvailability.offline ||
      kind == FundusCatalogSourceKind.offline;
}

/// Repository façade for the single library catalog.
///
/// The app may receive entries from a local vault, a peer mirror, or an
/// offline copy, but the UI consumes only [catalog].  Source updates replace
/// one source atomically and preserve all other sources.  This is intentionally
/// an in-memory façade for now; persistence remains in the Core vault index and
/// the remote catalog mirror, so there is no second cache format to migrate.
final class FundusCatalogRepository {
  FundusCatalogRepository(Iterable<FundusCatalogEntry> entries)
    : _catalog = FundusLibraryCatalog(entries);

  FundusCatalogRepository.empty() : _catalog = FundusLibraryCatalog(const []);

  final FundusLibraryCatalog _catalog;

  FundusLibraryCatalog get catalog => _catalog;

  /// Creates a repository from all currently known source entries.  Keeping
  /// this operation pure makes it safe to call while rebuilding the widget
  /// tree and easy to verify in unit tests.
  static FundusCatalogRepository compose(
    Iterable<FundusCatalogEntry> entries,
  ) => FundusCatalogRepository(entries);

  /// Returns a new repository with the entries for [sourceId] replaced.
  /// Existing entries from other sources are retained unchanged.
  FundusCatalogRepository replaceSource(
    String sourceId,
    Iterable<FundusCatalogEntry> entries,
  ) {
    final retained = _catalog.entries.where(
      (entry) => entry.source.id != sourceId,
    );
    return FundusCatalogRepository([...retained, ...entries]);
  }

  /// Returns a new repository without a source.  This is used when a peer is
  /// unpaired; an unreachable peer remains present and should instead be
  /// represented by an availability update.
  FundusCatalogRepository removeSource(String sourceId) =>
      FundusCatalogRepository(
        _catalog.entries.where((entry) => entry.source.id != sourceId),
      );
}

final class FundusCatalogEntry {
  const FundusCatalogEntry({required this.work, required this.source});

  final LibraryWorkSummary work;
  final FundusCatalogSource source;

  /// Stable within a client even when a remote source changes its IP address.
  String get key => '${source.id}:${_canonicalWorkId(work.id)}';

  static String _canonicalWorkId(String id) {
    if (!id.startsWith('offline:')) return id;
    final parts = id.substring('offline:'.length).split('/');
    return parts.isEmpty ? id : parts.last;
  }

  bool get available =>
      source.availability == FundusCatalogAvailability.available;
  bool get offlineAvailable => work.offline || source.isOffline;

  FundusCatalogEntry copyWith({
    LibraryWorkSummary? work,
    FundusCatalogSource? source,
  }) => FundusCatalogEntry(
    work: work ?? this.work,
    source: source ?? this.source,
  );
}

/// Unified work catalog used by all library layouts.
///
/// Local and offline summaries may overlap after a download. In that case the
/// offline entry wins, while the original source is retained in the summary.
/// Remote entries use their server/library identity as source id and therefore
/// remain addressable after the server's network address changes.
final class FundusLibraryCatalog {
  FundusLibraryCatalog(Iterable<FundusCatalogEntry> entries)
    : _entries = _deduplicate(entries);

  final List<FundusCatalogEntry> _entries;

  List<FundusCatalogEntry> get entries => List.unmodifiable(_entries);
  List<LibraryWorkSummary> get works => [
    for (final entry in _entries) entry.work,
  ];

  FundusCatalogEntry? byKey(String key) {
    for (final entry in _entries) {
      if (entry.key == key) return entry;
    }
    return null;
  }

  FundusLibraryCatalog merge(FundusLibraryCatalog other) =>
      FundusLibraryCatalog([..._entries, ...other._entries]);

  static List<FundusCatalogEntry> _deduplicate(
    Iterable<FundusCatalogEntry> input,
  ) {
    final result = <String, FundusCatalogEntry>{};
    for (final entry in input) {
      final previous = result[entry.key];
      if (previous == null || _priority(entry) > _priority(previous)) {
        result[entry.key] = entry;
      }
    }
    return result.values.toList(growable: false);
  }

  static int _priority(FundusCatalogEntry entry) {
    if (entry.source.availability == FundusCatalogAvailability.offline ||
        entry.source.kind == FundusCatalogSourceKind.offline) {
      return 3;
    }
    return switch (entry.source.kind) {
      FundusCatalogSourceKind.local => 2,
      FundusCatalogSourceKind.remote => 1,
      FundusCatalogSourceKind.offline => 3,
    };
  }

  static FundusCatalogSource localSource(String name, {String? sourceId}) =>
      FundusCatalogSource(
        id: sourceId ?? 'local:$name',
        kind: FundusCatalogSourceKind.local,
        displayName: name,
      );

  static FundusCatalogSource offlineSource({
    required String serverId,
    required String libraryId,
    required String displayName,
  }) => FundusCatalogSource(
    // Keep the same source identity as the online peer. Offline availability
    // is a state of that source, not a second library.
    id: 'remote:$serverId/$libraryId',
    kind: FundusCatalogSourceKind.remote,
    displayName: displayName,
    availability: FundusCatalogAvailability.offline,
  );

  static FundusCatalogSource remoteSource({
    required String serverId,
    required String libraryId,
    required String displayName,
    FundusCatalogAvailability availability =
        FundusCatalogAvailability.available,
  }) => FundusCatalogSource(
    id: 'remote:$serverId/$libraryId',
    kind: FundusCatalogSourceKind.remote,
    displayName: displayName,
    availability: availability,
  );
}
