import 'dart:convert';
import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:sqlite3/sqlite3.dart';
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
    expect(tracks.first.audioMetadata?.container, 'MP3');
    expect(tracks.first.audioMetadata?.codec, 'MP3');
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
    final progressSummary = library.listWorks().single;
    expect(
      progressSummary.progressPosition,
      const Duration(minutes: 12, seconds: 7),
    );
    expect(progressSummary.progressDuration, const Duration(minutes: 30));
    expect(progressSummary.progressTrackIndex, 1);
    final duplicate = library.saveProgress(
      workId: works.single.id,
      fileId: tracks[1].fileId,
      position: const Duration(minutes: 20),
      operationId: 'playback-operation-1',
    );
    expect(duplicate.revision, 1);
    expect(duplicate.position.displayValue, '00:12:07');
    final later = library.saveProgress(
      workId: works.single.id,
      fileId: tracks.first.fileId,
      position: const Duration(minutes: 2),
      operationId: 'playback-operation-2',
      deviceId: 'phone-test',
    );
    expect(later.revision, 2);
    final revisions = library.listProgressRevisions(works.single.id);
    expect(revisions.map((item) => item.revision), [2, 1]);
    expect(revisions.first.deviceId, 'phone-test');
    final restoredRevision = library.restoreProgressRevision(
      workId: works.single.id,
      revision: 1,
      operationId: 'restore-operation-1',
      deviceId: 'desktop-test',
    );
    expect(restoredRevision.revision, 3);
    expect(restoredRevision.position.displayValue, '00:12:07');
    final repeatedRestore = library.restoreProgressRevision(
      workId: works.single.id,
      revision: 1,
      operationId: 'restore-operation-1',
      deviceId: 'desktop-test',
    );
    expect(repeatedRestore.revision, 3);
    library.close();

    final reopened = await FundusLibrary.open(root);
    addTearDown(reopened.close);
    expect(reopened.manifest.libraryId, isNotEmpty);
    expect(reopened.listWorks().single.title, 'Winnetou I');
    await reopened.index().drain<void>();
    final rescannedWork = reopened.listWorks().single;
    expect(rescannedWork.id, works.single.id);
    final resumed = reopened.loadProgress(rescannedWork.id)!;
    expect(
      reopened.playbackTracks(rescannedWork.id).first.audioMetadata?.codec,
      'MP3',
    );
    expect(resumed.fileId, tracks[1].fileId);
    expect(resumed.position.displayValue, '00:12:07');
    expect(resumed.revision, 3);
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

  test('persists a work-based playback session exactly', () async {
    final root = await Directory.systemTemp.createTemp('fundus-session-');
    addTearDown(() => root.delete(recursive: true));
    final first = Directory('${root.path}/Audiobooks/Autor/Serie/01 - Eins');
    final second = Directory('${root.path}/Audiobooks/Autor/Serie/02 - Zwei');
    await first.create(recursive: true);
    await second.create(recursive: true);
    await File('${first.path}/eins.mp3').writeAsBytes([1]);
    await File('${second.path}/zwei-a.mp3').writeAsBytes([2]);
    await File('${second.path}/zwei-b.mp3').writeAsBytes([3]);

    final library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final works = library.listWorks()
      ..sort((a, b) => a.seriesSequence!.compareTo(b.seriesSequence!));
    final secondTracks = library.playbackTracks(works[1].id);
    final session = PlaybackSession(
      id: 'current-session',
      items: [
        PlaybackSessionItem(
          workId: works[0].id,
          fileIds: library
              .playbackTracks(works[0].id)
              .map((track) => track.fileId)
              .toList(),
          position: 0,
        ),
        PlaybackSessionItem(
          workId: works[1].id,
          fileIds: secondTracks.map((track) => track.fileId).toList(),
          position: 1,
        ),
      ],
      currentIndex: 1,
      currentPosition: MediaPosition(
        kind: MediaPositionKind.time,
        numericValue: 75,
        total: 900,
        fileId: secondTracks[1].fileId,
      ),
      repeatMode: RepeatMode.all,
      shuffleOrder: const [1, 0],
    );
    final firstSession = library.savePlaybackSession(
      session,
      deviceId: 'android-test',
    );
    final secondSession = library.savePlaybackSession(
      session,
      deviceId: 'android-test',
    );
    expect(firstSession.revision, 1);
    expect(secondSession.revision, 2);
    expect(
      () => library.savePlaybackSession(
        session,
        deviceId: 'stale-device',
        expectedRevision: 1,
      ),
      throwsA(
        isA<PlaybackSessionRevisionConflict>().having(
          (error) => error.current.revision,
          'current revision',
          2,
        ),
      ),
    );
    final playlist = library.savePlaylist(
      name: 'Unterwegs hören',
      workIds: [works[1].id, works[0].id],
      mediaType: 'audiobook',
    );
    expect(playlist.revision, 1);
    final updatedPlaylist = library.savePlaylist(
      playlistId: playlist.id,
      name: 'Unterwegs hören',
      workIds: [works[0].id, works[1].id],
      mediaType: 'audiobook',
    );
    expect(updatedPlaylist.revision, 2);
    library.close();

    final reopened = await FundusLibrary.open(root);
    addTearDown(reopened.close);
    final restored = reopened.latestPlaybackSession()!;
    expect(restored.id, 'current-session');
    expect(restored.items.map((item) => item.workId), [
      works[0].id,
      works[1].id,
    ]);
    expect(
      restored.items[1].fileIds,
      secondTracks.map((track) => track.fileId),
    );
    expect(restored.currentIndex, 1);
    expect(restored.currentPosition.numericValue, 75);
    expect(restored.currentPosition.fileId, secondTracks[1].fileId);
    expect(restored.repeatMode, RepeatMode.all);
    expect(restored.shuffleOrder, [1, 0]);
    expect(restored.revision, 2);
    expect(restored.updatedAt, isNotNull);
    final restoredPlaylist = reopened.listPlaylists().single;
    expect(restoredPlaylist.id, playlist.id);
    expect(restoredPlaylist.name, 'Unterwegs hören');
    expect(restoredPlaylist.mediaType, 'audiobook');
    expect(restoredPlaylist.workIds, [works[0].id, works[1].id]);
    expect(restoredPlaylist.revision, 2);
    reopened.deletePlaylist(playlist.id);
    expect(reopened.listPlaylists(), isEmpty);
    final empty = reopened.savePlaylist(
      name: 'Noch leer',
      workIds: const [],
      mediaType: 'video',
    );
    expect(empty.workIds, isEmpty);
    expect(empty.mediaType, 'video');
  });

  test(
    'does not resolve a manipulated cover path outside the library',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-safe-cover-');
      addTearDown(() => root.delete(recursive: true));
      final book = Directory('${root.path}/Autor/Serie/01 - Titel');
      await book.create(recursive: true);
      await File('${book.path}/Titel.mp3').writeAsBytes([1, 2, 3]);
      final library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      library.close();

      final database = sqlite3.open('${root.path}/.library/index.db');
      database.execute(
        "UPDATE works SET generated_cover_path = '../../private-cover.jpg'",
      );
      database.close();

      final reopened = await FundusLibrary.open(root);
      addTearDown(reopened.close);
      expect(reopened.listWorks().single.coverPath, isNull);
    },
  );

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

  test('uses embedded identity tags for a loose audiobook', () async {
    final root = await Directory.systemTemp.createTemp('fundus-tagged-');
    addTearDown(() => root.delete(recursive: true));
    final book = Directory('${root.path}/Audiobooks/Neutraler Ordner');
    await book.create(recursive: true);
    await File(
      '${book.path}/audio.m4b',
    ).writeAsBytes(_m4bWithIdentityMetadata());

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final work = library.listWorks().single;
    expect(work.title, 'Titel aus Tags');
    expect(work.author, 'Autor aus Tags');
    expect(work.series, 'Serie aus Tags');
    expect(work.seriesSequence, 4);
    expect(work.language, 'German');
    final sidecar = await File('${book.path}/_fundus/meta.yaml').readAsString();
    expect(sidecar, contains('"title": "Titel aus Tags"'));
    expect(sidecar, contains('"author": "Autor aus Tags"'));

    await File('${book.path}/audio.m4b').writeAsBytes(
      _m4bWithIdentityMetadata(title: 'Später veränderter Dateitag'),
    );
    await library.index().drain<void>();
    expect(library.listWorks().single.title, 'Titel aus Tags');
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
      await File('${original.path}/cover.jpg').writeAsBytes([0xff, 0xd8, 0xff]);

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

  test(
    'recognizes a moved audiobook even when its sidecar is missing',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-move-no-sidecar-',
      );
      addTearDown(() => root.delete(recursive: true));
      final original = Directory(
        '${root.path}/Autor/Serie/01 - Bleibender Titel',
      );
      await original.create(recursive: true);
      await File('${original.path}/01 - Anfang.mp3').writeAsBytes([1, 2, 3]);
      await File('${original.path}/02 - Ende.mp3').writeAsBytes([4, 5, 6]);
      await File('${original.path}/cover.jpg').writeAsBytes([0xff, 0xd8, 0xff]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();
      final before = library.listWorks().single;
      final beforeTracks = library.playbackTracks(before.id);
      library.saveProgress(
        workId: before.id,
        fileId: beforeTracks[1].fileId,
        position: const Duration(minutes: 9, seconds: 8),
        operationId: 'move-without-sidecar',
      );
      await Directory('${original.path}/_fundus').delete(recursive: true);
      await original.rename('${root.path}/Verschobenes Hörbuch');

      await library.index().drain<void>();

      final after = library.listWorks().single;
      final afterTracks = library.playbackTracks(after.id);
      expect(after.id, before.id);
      expect(after.title, 'Bleibender Titel');
      expect(after.coverPath, isNotNull);
      expect(library.loadProgress(after.id)!.fileId, afterTracks[1].fileId);
      expect(library.loadProgress(after.id)!.position.displayValue, '00:09:08');
    },
  );

  test('keeps a cached cover when only the audio file is moved', () async {
    final root = await Directory.systemTemp.createTemp('fundus-cover-move-');
    addTearDown(() => root.delete(recursive: true));
    final original = Directory('${root.path}/Autor/Serie/01 - Titel');
    await original.create(recursive: true);
    final audio = File('${original.path}/Titel.mp3');
    await audio.writeAsBytes([1, 2, 3]);
    await File(
      '${original.path}/cover.jpg',
    ).writeAsBytes([0xff, 0xd8, 0xff, 0xd9]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final before = library.listWorks().single;
    expect(before.coverPath, endsWith('cover.jpg'));
    await Directory('${original.path}/_fundus').delete(recursive: true);
    final moved = Directory('${root.path}/Verschoben');
    await moved.create();
    await audio.rename('${moved.path}/Titel.mp3');

    await library.index().drain<void>();

    final after = library.listWorks().single;
    expect(after.id, before.id);
    expect(after.coverPath, contains('.library/covers'));
    expect(await File(after.coverPath!).exists(), isTrue);
    expect(library.playbackTracks(after.id), hasLength(1));
  });

  test('imports ABS metadata and description for a loose audiobook', () async {
    final root = await Directory.systemTemp.createTemp('fundus-abs-json-');
    addTearDown(() => root.delete(recursive: true));
    final book = Directory('${root.path}/Neutraler Ordner');
    await book.create(recursive: true);
    await File('${book.path}/audio.mp3').writeAsBytes([1, 2, 3]);
    await File('${book.path}/metadata.json').writeAsString(
      jsonEncode({
        'title': 'Titel aus ABS',
        'authors': ['ABS Autor'],
        'narrators': ['ABS Sprecher'],
        'series': ['ABS Serie #2'],
        'genres': ['Fantasy'],
        'tags': ['Favorit'],
        'language': 'de',
        'description': '<p>Erster Absatz.</p><p>Zweiter Absatz.</p>',
        'publisher': 'ABS Verlag',
        'publishedYear': 2025,
      }),
    );

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final work = library.listWorks().single;
    expect(work.title, 'Titel aus ABS');
    expect(work.author, 'ABS Autor');
    expect(work.series, 'ABS Serie');
    expect(work.seriesSequence, 2);
    expect(work.description, 'Erster Absatz.\n\nZweiter Absatz.');
    expect(work.narrators, ['ABS Sprecher']);
    expect(work.publisher, 'ABS Verlag');
    expect(work.publishedYear, 2025);
    expect(library.loadAnnotations(work.id).tags, ['Fantasy', 'Favorit']);
  });

  test(
    'merges a portable work into an older entry at its destination',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-move-collision-',
      );
      addTearDown(() => root.delete(recursive: true));
      final destination = Directory('${root.path}/Autor/Serie/01 - Titel');
      await destination.create(recursive: true);
      final audio = File('${destination.path}/Titel.mp3');
      await audio.writeAsBytes([1, 2, 3]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();
      final destinationWork = library.listWorks().single;
      final destinationTrack = library
          .playbackTracks(destinationWork.id)
          .single;
      await library.addBookmark(
        workId: destinationWork.id,
        fileId: destinationTrack.fileId,
        position: const Duration(minutes: 3),
        label: 'Aus altem Zieleintrag',
      );
      await Directory('${destination.path}/_fundus').delete(recursive: true);
      final loose = await destination.rename('${root.path}/Loser Titel');
      await File('${loose.path}/Titel.mp3').writeAsBytes([1, 2, 3, 4]);
      await library.index().drain<void>();
      final portableWork = library.listWorks().single;
      expect(portableWork.id, isNot(destinationWork.id));
      final looseTrack = library.playbackTracks(portableWork.id).single;
      library.saveProgress(
        workId: portableWork.id,
        fileId: looseTrack.fileId,
        position: const Duration(minutes: 7),
        operationId: 'portable-collision-progress',
      );
      await library.replaceWorkTags(portableWork.id, ['Bleibt erhalten']);

      await loose.rename(destination.path);
      await library.index().drain<void>();

      final merged = library.listWorks().single;
      expect(merged.id, portableWork.id);
      expect(library.workDirectoryPath(merged.id), destination.path);
      expect(library.playbackTracks(merged.id), hasLength(1));
      expect(
        library.loadProgress(merged.id)!.position.displayValue,
        '00:07:00',
      );
      expect(library.loadAnnotations(merged.id).tags, ['Bleibt erhalten']);
      final bookmark = library.loadAnnotations(merged.id).bookmarks.single;
      expect(bookmark.label, 'Aus altem Zieleintrag');
      expect(bookmark.fileId, library.playbackTracks(merged.id).single.fileId);
    },
  );

  test(
    'keeps a missing work and restores it with progress and annotations',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'fundus-missing-work-',
      );
      addTearDown(() => root.delete(recursive: true));
      final original = Directory('${root.path}/Autor/Serie/01 - Titel');
      await original.create(recursive: true);
      final audio = File('${original.path}/Kapitel.mp3');
      await audio.writeAsBytes([1, 2, 3, 4]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();
      final work = library.listWorks().single;
      final track = library.playbackTracks(work.id).single;
      library.saveProgress(
        workId: work.id,
        fileId: track.fileId,
        position: const Duration(minutes: 19, seconds: 8),
        operationId: 'before-disappearance',
      );
      await library.replaceWorkTags(work.id, ['Nicht verlieren']);
      await library.saveWorkNote(work.id, 'Bleibt auch ohne Datei erhalten.');
      await library.addBookmark(
        workId: work.id,
        fileId: track.fileId,
        position: const Duration(minutes: 7),
        label: 'Merker',
      );

      await original.delete(recursive: true);
      await library.index().drain<void>();

      expect(library.listWorks(), isEmpty);
      final missing = library.listWorks(includeMissing: true).single;
      expect(missing.id, work.id);
      expect(missing.available, isFalse);
      expect(missing.status, 'missing');
      expect(missing.fileCount, 0);
      expect(
        library.loadProgress(missing.id)!.position.displayValue,
        '00:19:08',
      );
      final retained = library.loadAnnotations(missing.id);
      expect(retained.tags, ['Nicht verlieren']);
      expect(
        retained.notes.single.markdown,
        'Bleibt auch ohne Datei erhalten.',
      );
      expect(retained.bookmarks.single.label, 'Merker');

      final restored = Directory('${root.path}/Wieder da');
      await restored.create(recursive: true);
      await File('${restored.path}/Kapitel.mp3').writeAsBytes([1, 2, 3, 4]);
      await library.index().drain<void>();

      final available = library.listWorks().single;
      expect(available.id, work.id);
      expect(available.available, isTrue);
      expect(library.workDirectoryPath(available.id), restored.path);
      expect(
        library.loadProgress(available.id)!.position.displayValue,
        '00:19:08',
      );
      expect(library.loadAnnotations(available.id).tags, ['Nicht verlieren']);
    },
  );

  test('only explicitly deletes works that are already missing', () async {
    final root = await Directory.systemTemp.createTemp(
      'fundus-delete-missing-',
    );
    addTearDown(() => root.delete(recursive: true));
    final book = Directory('${root.path}/Autor/Titel');
    await book.create(recursive: true);
    await File('${book.path}/Titel.mp3').writeAsBytes([9, 8, 7]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final work = library.listWorks().single;
    expect(() => library.deleteMissingWork(work.id), throwsStateError);
    await library.replaceWorkTags(work.id, ['Temporär']);

    await book.delete(recursive: true);
    await library.index().drain<void>();
    expect(library.listWorks(includeMissing: true).single.id, work.id);

    library.deleteMissingWork(work.id);

    expect(library.listWorks(includeMissing: true), isEmpty);
    expect(library.loadProgress(work.id), isNull);
    expect(library.loadAnnotations(work.id).tags, isEmpty);
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
        ..._atom('©lan', [
          ..._atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...'de-DE'.codeUnits]),
        ]),
      ]),
    ]),
  ]),
]);

List<int> _m4bWithIdentityMetadata({String title = 'Titel aus Tags'}) =>
    _atom('moov', [
      ..._atom('udta', [
        ..._atom('meta', [
          0,
          0,
          0,
          0,
          ..._atom('ilst', [
            ..._textTag('©nam', title),
            ..._textTag('aART', 'Autor aus Tags'),
            ..._freeformTag('SERIES', 'Serie aus Tags'),
            ..._freeformTag('PART', '4'),
            ..._freeformTag('LANGUAGE', 'German'),
          ]),
        ]),
      ]),
    ]);

List<int> _textTag(String type, String value) => _atom(type, [
  ..._atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...value.codeUnits]),
]);

List<int> _freeformTag(String name, String value) => _atom('----', [
  ..._atom('mean', [0, 0, 0, 0, ...'com.apple.iTunes'.codeUnits]),
  ..._atom('name', [0, 0, 0, 0, ...name.codeUnits]),
  ..._atom('data', [0, 0, 0, 1, 0, 0, 0, 0, ...value.codeUnits]),
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
