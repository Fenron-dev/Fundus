import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import 'media_byte_source.dart';
import '../server/fundus_remote_client.dart';

/// Origin of a media asset.  This is data carried by an asset, not a branch
/// in the reader or player widget tree.
enum FundusMediaAssetOrigin { vault, peer, offline, memory }

/// Identifies one media file without exposing transport details to a reader.
///
/// [relativePath] is used for a vault source and [localPath] for an offline
/// copy.  Peer assets use [id] as the opaque server file id.  Keeping the
/// fields explicit prevents accidentally treating an absolute server path as
/// a local file path.
final class FundusMediaAsset {
  const FundusMediaAsset({
    required this.id,
    required this.name,
    required this.origin,
    required this.sourceId,
    this.relativePath,
    this.localPath,
    this.contentLength,
    this.bytes,
  });

  const FundusMediaAsset.vault({
    required String id,
    required String name,
    required String sourceId,
    required String relativePath,
    int? contentLength,
  }) : this(
         id: id,
         name: name,
         origin: FundusMediaAssetOrigin.vault,
         sourceId: sourceId,
         relativePath: relativePath,
         contentLength: contentLength,
       );

  const FundusMediaAsset.offline({
    required String id,
    required String name,
    required String sourceId,
    required String localPath,
    int? contentLength,
  }) : this(
         id: id,
         name: name,
         origin: FundusMediaAssetOrigin.offline,
         sourceId: sourceId,
         localPath: localPath,
         contentLength: contentLength,
       );

  const FundusMediaAsset.peer({
    required String id,
    required String name,
    required String sourceId,
    int? contentLength,
  }) : this(
         id: id,
         name: name,
         origin: FundusMediaAssetOrigin.peer,
         sourceId: sourceId,
         contentLength: contentLength,
       );

  FundusMediaAsset.memory({
    required String id,
    required String name,
    required Uint8List bytes,
    String sourceId = 'memory',
  }) : this(
         id: id,
         name: name,
         origin: FundusMediaAssetOrigin.memory,
         sourceId: sourceId,
         contentLength: bytes.length,
         bytes: bytes,
       );

  final String id;
  final String name;
  final FundusMediaAssetOrigin origin;
  final String sourceId;
  final String? relativePath;
  final String? localPath;
  final int? contentLength;
  final Uint8List? bytes;
}

/// Source gateway used by all readers and media engines.
abstract interface class FundusSourceGateway {
  bool supports(FundusMediaAsset asset);

  Future<FundusMediaByteSource> open(FundusMediaAsset asset);
}

/// Opens files from one local vault while refusing paths that escape its root.
final class FundusVaultSourceGateway implements FundusSourceGateway {
  FundusVaultSourceGateway(Directory root) : root = root.absolute;

  final Directory root;

  @override
  bool supports(FundusMediaAsset asset) =>
      asset.origin == FundusMediaAssetOrigin.vault;

  @override
  Future<FundusMediaByteSource> open(FundusMediaAsset asset) async {
    if (!supports(asset)) {
      throw StateError('Die Vault-Quelle unterstützt dieses Asset nicht.');
    }
    final relative = asset.relativePath;
    if (relative == null || relative.trim().isEmpty) {
      throw ArgumentError('Ein Vault-Asset benötigt einen relativen Pfad.');
    }
    final file = _resolveRelative(relative);
    if (!await file.exists()) {
      throw FileSystemException(
        'Die Mediendatei ist nicht verfügbar.',
        file.path,
      );
    }
    return LocalFileMediaByteSource(file);
  }

  File _resolveRelative(String relativePath) {
    final candidate = File(
      p.normalize(p.join(root.path, relativePath)),
    ).absolute;
    if (!p.isWithin(root.path, candidate.path) && candidate.path != root.path) {
      throw const FileSystemException('Unsicherer relativer Medienpfad.');
    }
    return candidate;
  }
}

/// Opens a device-local offline copy.  The canonical source id remains on the
/// asset so a downloaded file can still be attributed to its peer library.
final class FundusOfflineSourceGateway implements FundusSourceGateway {
  const FundusOfflineSourceGateway();

  @override
  bool supports(FundusMediaAsset asset) =>
      asset.origin == FundusMediaAssetOrigin.offline;

  @override
  Future<FundusMediaByteSource> open(FundusMediaAsset asset) async {
    if (!supports(asset)) {
      throw StateError('Die Offline-Quelle unterstützt dieses Asset nicht.');
    }
    final path = asset.localPath;
    if (path == null || path.trim().isEmpty) {
      throw ArgumentError('Ein Offline-Asset benötigt einen lokalen Pfad.');
    }
    final file = File(path).absolute;
    if (!await file.exists()) {
      throw FileSystemException(
        'Die Offline-Kopie ist nicht verfügbar.',
        file.path,
      );
    }
    return LocalFileMediaByteSource(file);
  }
}

typedef FundusPeerRangeProvider =
    Future<Uint8List> Function(FundusMediaAsset asset, {int? start, int? end});

/// Opens opaque peer files through a range provider.  The provider is kept
/// injectable so the gateway is testable without a live server and can later
/// be backed by a pooled HTTP client.
final class FundusPeerSourceGateway implements FundusSourceGateway {
  const FundusPeerSourceGateway({required this.readRange});

  /// Creates a gateway backed by the existing pinned remote client.
  factory FundusPeerSourceGateway.fromClient({
    required FundusRemoteClient client,
    required FundusRemoteServer server,
    required String libraryId,
  }) => FundusPeerSourceGateway(
    readRange: (asset, {start, end}) async {
      final requestedEnd = end == null ? null : end - 1;
      final range = start == null && requestedEnd == null
          ? null
          : 'bytes=${start ?? 0}-${requestedEnd ?? ''}';
      final remote = await client.openContent(
        server,
        libraryId: libraryId,
        fileId: asset.id,
        range: range,
      );
      try {
        final bytes = await remote.response
            .timeout(const Duration(seconds: 20))
            .expand((chunk) => chunk)
            .toList();
        return Uint8List.fromList(bytes);
      } finally {
        remote.close();
      }
    },
  );

  final FundusPeerRangeProvider readRange;

  @override
  bool supports(FundusMediaAsset asset) =>
      asset.origin == FundusMediaAssetOrigin.peer;

  @override
  Future<FundusMediaByteSource> open(FundusMediaAsset asset) async {
    if (!supports(asset)) {
      throw StateError('Die Peer-Quelle unterstützt dieses Asset nicht.');
    }
    return RangedMediaByteSource(
      id: '${asset.sourceId}:${asset.id}',
      contentLength: asset.contentLength,
      readRange: ({start, end}) => readRange(asset, start: start, end: end),
    );
  }
}

final class FundusMemorySourceGateway implements FundusSourceGateway {
  const FundusMemorySourceGateway();

  @override
  bool supports(FundusMediaAsset asset) =>
      asset.origin == FundusMediaAssetOrigin.memory;

  @override
  Future<FundusMediaByteSource> open(FundusMediaAsset asset) async {
    if (!supports(asset)) {
      throw StateError('Die Speicherquelle unterstützt dieses Asset nicht.');
    }
    final bytes = asset.bytes;
    if (bytes == null) {
      throw ArgumentError('Ein Speicher-Asset benötigt Byte-Inhalt.');
    }
    return MemoryMediaByteSource(asset.id, bytes);
  }
}

/// Routes an asset to exactly one transport gateway.  A missing gateway is a
/// programmer/configuration error instead of silently falling back to a
/// different source (which could expose the wrong copy of a work).
final class FundusSourceGatewayRouter implements FundusSourceGateway {
  const FundusSourceGatewayRouter(this.gateways);

  final List<FundusSourceGateway> gateways;

  @override
  bool supports(FundusMediaAsset asset) =>
      gateways.any((gateway) => gateway.supports(asset));

  @override
  Future<FundusMediaByteSource> open(FundusMediaAsset asset) {
    for (final gateway in gateways) {
      if (gateway.supports(asset)) return gateway.open(asset);
    }
    throw StateError(
      'Keine Medienquelle für ${asset.origin.name} (${asset.name}) registriert.',
    );
  }
}

/// Bridges the gateway to the core publication reader contract.
extension FundusSourceGatewayPublication on FundusSourceGateway {
  Future<PublicationSource> openPublicationSource(
    FundusMediaAsset asset, {
    PublicationSourceKind? kind,
  }) async {
    final bytes = await open(asset);
    final sourceKind =
        kind ??
        switch (asset.origin) {
          FundusMediaAssetOrigin.vault => PublicationSourceKind.local,
          FundusMediaAssetOrigin.peer => PublicationSourceKind.remote,
          FundusMediaAssetOrigin.offline => PublicationSourceKind.offline,
          FundusMediaAssetOrigin.memory => PublicationSourceKind.memory,
        };
    return PublicationMediaByteSource(
      bytes,
      kind: sourceKind,
      name: asset.name,
    );
  }
}
