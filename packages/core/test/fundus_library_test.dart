import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('creates, indexes and reopens a portable library', () async {
    final root = await Directory.systemTemp.createTemp('fundus-library-');
    addTearDown(() => root.delete(recursive: true));
    final book = Directory('${root.path}/Karl May/Winnetou/01 - Winnetou I');
    await book.create(recursive: true);
    await File('${book.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);
    await File('${book.path}/02 - Kapitel.mp3').writeAsBytes([4, 5]);
    await File('${book.path}/cover.jpg').writeAsBytes([6]);

    final library = await FundusLibrary.create(root);
    final events = await library.index().toList();
    final works = library.listWorks();

    expect(events.last.phase, LibraryIndexPhase.completed);
    expect(events.last.fileCount, 3);
    expect(works, hasLength(1));
    expect(works.single.title, 'Winnetou I');
    expect(works.single.author, 'Karl May');
    expect(works.single.series, 'Winnetou');
    expect(works.single.seriesSequence, 1);
    expect(works.single.fileCount, 2);
    expect(works.single.coverPath, endsWith('cover.jpg'));

    final tracks = library.playbackTracks(works.single.id);
    expect(tracks.map((track) => track.title), [
      '01 - Kapitel.mp3',
      '02 - Kapitel.mp3',
    ]);
    final saved = library.saveProgress(
      workId: works.single.id,
      fileId: tracks[1].fileId,
      position: const Duration(minutes: 12, seconds: 7),
      duration: const Duration(minutes: 30),
      operationId: 'playback-operation-1',
    );
    expect(saved.revision, 1);
    expect(saved.position.displayValue, '00:12:07');
    final duplicate = library.saveProgress(
      workId: works.single.id,
      fileId: tracks[1].fileId,
      position: const Duration(minutes: 20),
      operationId: 'playback-operation-1',
    );
    expect(duplicate.revision, 1);
    expect(duplicate.position.displayValue, '00:12:07');
    library.close();

    final reopened = await FundusLibrary.open(root);
    addTearDown(reopened.close);
    expect(reopened.manifest.libraryId, isNotEmpty);
    expect(reopened.listWorks().single.title, 'Winnetou I');
    await reopened.index().drain<void>();
    final rescannedWork = reopened.listWorks().single;
    expect(rescannedWork.id, works.single.id);
    final resumed = reopened.loadProgress(rescannedWork.id)!;
    expect(resumed.fileId, tracks[1].fileId);
    expect(resumed.position.displayValue, '00:12:07');
  });

  test('caches and resolves embedded M4B artwork', () async {
    final root = await Directory.systemTemp.createTemp('fundus-artwork-');
    addTearDown(() => root.delete(recursive: true));
    final book = Directory('${root.path}/Autor/Serie/01 - Titel');
    await book.create(recursive: true);
    await File('${book.path}/Titel.m4b').writeAsBytes(_m4bWithJpegCover());

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final coverPath = library.listWorks().single.coverPath;
    expect(coverPath, isNotNull);
    expect(coverPath, endsWith('.jpg'));
    final coverBytes = await File(coverPath!).readAsBytes();
    expect(coverBytes.sublist(0, 3), [0xff, 0xd8, 0xff]);
  });

  test('open rejects a directory without a manifest', () async {
    final root = await Directory.systemTemp.createTemp('fundus-empty-');
    addTearDown(() => root.delete(recursive: true));

    expect(() => FundusLibrary.open(root), throwsA(isA<FileSystemException>()));
  });
}

List<int> _m4bWithJpegCover() => _atom('moov', [
  ..._atom('udta', [
    ..._atom('meta', [
      0,
      0,
      0,
      0,
      ..._atom('ilst', [
        ..._atom('covr', [
          ..._atom('data', [
            0,
            0,
            0,
            13,
            0,
            0,
            0,
            0,
            0xff,
            0xd8,
            0xff,
            0xe0,
            0xff,
            0xd9,
          ]),
        ]),
      ]),
    ]),
  ]),
]);

List<int> _atom(String type, List<int> payload) {
  final size = payload.length + 8;
  return [
    size >> 24,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type.codeUnits,
    ...payload,
  ];
}
