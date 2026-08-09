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
    expect(library.workDirectoryPath(works.single.id), book.path);

    final tracks = library.playbackTracks(works.single.id);
    expect(tracks.map((track) => track.title), [
      '01 - Kapitel.mp3',
      '02 - Kapitel.mp3',
    ]);
    final chapters = await library.playbackChapters(works.single.id);
    expect(chapters.map((chapter) => chapter.title), [
      '01 - Kapitel',
      '02 - Kapitel',
    ]);
    expect(chapters.map((chapter) => chapter.trackIndex), [0, 1]);
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

    final importedWork = library.listWorks().single;
    final coverPath = importedWork.coverPath;
    expect(coverPath, isNotNull);
    expect(coverPath, endsWith('.jpg'));
    expect(importedWork.language, 'de-DE');
    final coverBytes = await File(coverPath!).readAsBytes();
    expect(coverBytes.sublist(0, 3), [0xff, 0xd8, 0xff]);
  });

  test('indexes audiobooks inside the standard mixed-library root', () async {
    final root = await Directory.systemTemp.createTemp('fundus-mixed-');
    addTearDown(() => root.delete(recursive: true));
    final book = Directory(
      '${root.path}/Audiobooks/Autor/Serie/03 - Gemischte Bibliothek',
    );
    await book.create(recursive: true);
    await File('${book.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final work = library.listWorks().single;
    expect(work.author, 'Autor');
    expect(work.series, 'Serie');
    expect(work.seriesSequence, 3);
    expect(work.title, 'Gemischte Bibliothek');
    expect(await File('${root.path}/.library/config.yaml').exists(), isTrue);
  });

  test('indexes a loose audiobook directly in the library root', () async {
    final root = await Directory.systemTemp.createTemp('fundus-loose-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/Mein loses Hörbuch.m4b').writeAsBytes([1, 2, 3]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final work = library.listWorks().single;
    expect(work.title, 'Mein loses Hörbuch');
    expect(work.author, 'Unbekannt');
    expect(work.fileCount, 1);
    expect(library.workDirectoryPath(work.id), root.path);
    expect(await Directory('${root.path}/_fundus').exists(), isTrue);
  });

  test('restores tags notes and bookmarks from portable sidecars', () async {
    final root = await Directory.systemTemp.createTemp('fundus-sidecars-');
    addTearDown(() => root.delete(recursive: true));
    final book = Directory('${root.path}/Autor/Serie/01 - Titel');
    await book.create(recursive: true);
    await File('${book.path}/01 - Kapitel.mp3').writeAsBytes([1, 2, 3]);

    final library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final work = library.listWorks().single;
    final track = library.playbackTracks(work.id).single;
    await library.replaceWorkTags(work.id, ['Fantasy', 'Favorit']);
    await library.saveWorkNote(work.id, '# Eindruck\n\nSehr gutes Hörbuch.');
    await library.saveWorkNote(work.id, 'Zweite Notiz');
    await library.addBookmark(
      workId: work.id,
      fileId: track.fileId,
      position: const Duration(minutes: 12, seconds: 34),
      label: 'Wichtige Stelle',
    );

    final annotations = library.loadAnnotations(work.id);
    expect(annotations.tags, ['Fantasy', 'Favorit']);
    expect(annotations.notes, hasLength(2));
    expect(annotations.notes.first.markdown, 'Zweite Notiz');
    expect(
      annotations.bookmarks.single.position,
      const Duration(minutes: 12, seconds: 34),
    );
    final sidecars = Directory('${book.path}/_fundus');
    expect(await File('${sidecars.path}/meta.yaml').exists(), isTrue);
    expect(await File('${sidecars.path}/notes.md').exists(), isTrue);
    final portableNotes = await File(
      '${sidecars.path}/notes.md',
    ).readAsString();
    expect(portableNotes, contains('fundus-note:'));
    expect(portableNotes, contains('Sehr gutes Hörbuch'));
    expect(portableNotes, contains('Zweite Notiz'));
    expect(await File('${sidecars.path}/bookmarks.yaml').exists(), isTrue);
    library.close();

    await File('${root.path}/.library/index.db').delete();
    final rebuilt = await FundusLibrary.open(root);
    addTearDown(rebuilt.close);
    await rebuilt.index().drain<void>();
    final rebuiltWork = rebuilt.listWorks().single;
    final restored = rebuilt.loadAnnotations(rebuiltWork.id);

    expect(rebuiltWork.id, work.id);
    expect(restored.tags, ['Fantasy', 'Favorit']);
    expect(restored.notes, hasLength(2));
    expect(
      restored.notes.map((note) => note.markdown),
      contains('Zweite Notiz'),
    );
    expect(restored.bookmarks.single.label, 'Wichtige Stelle');
    expect(
      restored.bookmarks.single.position,
      const Duration(minutes: 12, seconds: 34),
    );
  });

  test(
    'keeps work progress and bookmarks when an audiobook is moved',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-move-');
      addTearDown(() => root.delete(recursive: true));
      final original = Directory('${root.path}/Autor/Serie/01 - Titel');
      await original.create(recursive: true);
      await File('${original.path}/01 - Anfang.mp3').writeAsBytes([1, 2, 3]);
      await File('${original.path}/02 - Ende.mp3').writeAsBytes([4, 5, 6]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();
      final originalWork = library.listWorks().single;
      final originalTracks = library.playbackTracks(originalWork.id);
      library.saveProgress(
        workId: originalWork.id,
        fileId: originalTracks[1].fileId,
        position: const Duration(minutes: 17, seconds: 42),
        operationId: 'before-move',
      );
      await library.addBookmark(
        workId: originalWork.id,
        fileId: originalTracks[1].fileId,
        position: const Duration(minutes: 12),
        label: 'Vor dem Verschieben',
      );
      await library.replaceWorkTags(originalWork.id, ['Bleibt erhalten']);

      final metadata = await File(
        '${original.path}/_fundus/meta.yaml',
      ).readAsString();
      expect(metadata, contains('"format_version": 2'));
      expect(metadata, contains('"work_id": "${originalWork.id}"'));
      expect(metadata, contains('"base_kind": "audiobook"'));

      final destinationParent = Directory(
        '${root.path}/Audiobooks/Autor/Serie',
      );
      await destinationParent.create(recursive: true);
      await original.rename('${destinationParent.path}/01 - Titel');
      await library.index().drain<void>();

      final movedWork = library.listWorks().single;
      final movedTracks = library.playbackTracks(movedWork.id);
      final progress = library.loadProgress(movedWork.id)!;
      final annotations = library.loadAnnotations(movedWork.id);
      expect(movedWork.id, originalWork.id);
      expect(progress.position.displayValue, '00:17:42');
      expect(progress.fileId, movedTracks[1].fileId);
      expect(progress.fileId, isNot(originalTracks[1].fileId));
      expect(annotations.tags, ['Bleibt erhalten']);
      expect(annotations.bookmarks.single.fileId, movedTracks[1].fileId);
      expect(annotations.bookmarks.single.label, 'Vor dem Verschieben');
    },
  );

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
        ..._atom('©lan', [
          ..._atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...'de-DE'.codeUnits]),
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
