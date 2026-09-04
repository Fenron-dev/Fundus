import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/fundus_media_source_gateway.dart';
import 'package:fundus/library/media_byte_source.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  test('vault gateway resolves relative paths and blocks traversal', () async {
    final root = await Directory.systemTemp.createTemp('fundus-vault-gateway-');
    addTearDown(() => root.delete(recursive: true));
    final media = File('${root.path}/Manga/chapter.cbz');
    await media.create(recursive: true);
    await media.writeAsBytes([1, 2, 3, 4]);
    final gateway = FundusVaultSourceGateway(root);

    final source = await gateway.open(
      const FundusMediaAsset.vault(
        id: 'file-1',
        name: 'chapter.cbz',
        sourceId: 'vault-1',
        relativePath: 'Manga/chapter.cbz',
      ),
    );
    expect(source, isA<LocalFileMediaByteSource>());
    expect(await source.read(start: 1, end: 3), [2, 3]);
    expect(
      gateway.open(
        const FundusMediaAsset.vault(
          id: 'escape',
          name: 'secret',
          sourceId: 'vault-1',
          relativePath: '../secret',
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'offline gateway opens a downloaded copy while preserving source id',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-offline-gateway-',
      );
      addTearDown(() => root.delete(recursive: true));
      final media = File('${root.path}/episode.mp4');
      await media.writeAsBytes([9, 8, 7]);
      final asset = FundusMediaAsset.offline(
        id: 'remote-file-1',
        name: 'episode.mp4',
        sourceId: 'remote:server/library',
        localPath: media.path,
      );
      final source = await const FundusOfflineSourceGateway().open(asset);

      expect(asset.sourceId, 'remote:server/library');
      expect(await source.length(), 3);
      expect(await source.read(), [9, 8, 7]);
    },
  );

  test('peer gateway forwards opaque id and half-open ranges', () async {
    FundusMediaAsset? requested;
    int? requestedStart;
    int? requestedEnd;
    final gateway = FundusPeerSourceGateway(
      readRange: (asset, {int? start, int? end}) async {
        requested = asset;
        requestedStart = start;
        requestedEnd = end;
        return Uint8List.fromList([4, 5]);
      },
    );
    final asset = const FundusMediaAsset.peer(
      id: 'opaque-file-id',
      name: 'book.epub',
      sourceId: 'remote:server/library',
      contentLength: 12,
    );
    final source = await gateway.open(asset);
    expect(await source.read(start: 4, end: 6), [4, 5]);
    expect(requested?.id, 'opaque-file-id');
    expect(requestedStart, 4);
    expect(requestedEnd, 6);
    expect(await source.length(), 12);
  });

  test('router and publication bridge keep one source entry point', () async {
    final router = FundusSourceGatewayRouter(const [
      FundusMemorySourceGateway(),
    ]);
    final asset = FundusMediaAsset.memory(
      id: 'memory-epub',
      name: 'book.epub',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

    expect(router.supports(asset), isTrue);
    final publication = await router.openPublicationSource(asset);
    expect(publication.kind, PublicationSourceKind.memory);
    expect(publication.name, 'book.epub');
    expect(await publication.read(const PublicationByteRange(0, 2)), [1, 2]);
  });
}
