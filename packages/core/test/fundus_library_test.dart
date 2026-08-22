import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

  test('persists named library views portably', () async {
    final root = await Directory.systemTemp.createTemp('fundus-views-');
    addTearDown(() => root.delete(recursive: true));
    final library = await FundusLibrary.create(root);
    addTearDown(library.close);

    final saved = await library.saveView(
      'Begonnene deutsche Hörbücher',
      const LibraryWorkQuery(
        kinds: {'audiobook'},
        progress: LibraryProgressFilter.inProgress,
        languages: {'de'},
        sort: LibraryWorkSort.recentlyListened,
      ),
    );
    expect(saved, hasLength(1));

    final loaded = await library.loadSavedViews();
    expect(loaded.single.name, 'Begonnene deutsche Hörbücher');
    expect(loaded.single.query.kinds, {'audiobook'});
    expect(loaded.single.query.progress, LibraryProgressFilter.inProgress);
    expect(loaded.single.query.languages, {'de'});
    expect(loaded.single.query.sort, LibraryWorkSort.recentlyListened);
    expect(
      await File('${root.path}/.library/saved_views.json').exists(),
      isTrue,
    );

    expect(await library.deleteSavedView(loaded.single.id), isEmpty);
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

  test(
    'manual audiobook metadata survives rescans and index rebuilds',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-edited-meta-');
      addTearDown(() => root.delete(recursive: true));
      final book = Directory('${root.path}/Unbekannt/Alte Serie/01 - Rohdaten');
      await book.create(recursive: true);
      await File('${book.path}/audio.mp3').writeAsBytes([1, 2, 3]);

      final library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      final original = library.listWorks().single;
      final edited = await library.updateWorkMetadata(
        workId: original.id,
        title: 'Manuell korrigierter Titel',
        subtitle: 'Eine Unterzeile',
        authors: const ['Erste Autorin', 'Zweiter Autor'],
        series: 'Neue Serie',
        seriesSequence: 2.5,
        narrators: const ['Sprecher Eins', 'Sprecher Zwei'],
        language: 'de',
        description: 'Eine portable Beschreibung.',
        publisher: 'Testverlag',
        publishedYear: 2026,
      );

      expect(edited.title, 'Manuell korrigierter Titel');
      expect(edited.authors, ['Erste Autorin', 'Zweiter Autor']);
      expect(edited.series, 'Neue Serie');
      expect(edited.seriesSequence, 2.5);
      expect(edited.narrators, ['Sprecher Eins', 'Sprecher Zwei']);
      expect(edited.language, 'de');
      expect(edited.description, 'Eine portable Beschreibung.');
      expect(edited.metadataOrigins['title']?.source, WorkMetadataSource.user);
      expect(
        edited.metadataOrigins['narrators']?.source,
        WorkMetadataSource.user,
      );

      await File('${book.path}/metadata.json').writeAsString(
        jsonEncode({
          'title': 'Späterer ABS-Titel',
          'authors': ['Anderer ABS-Autor'],
          'series': ['Andere ABS-Serie #9'],
          'language': 'en',
        }),
      );

      await library.index().drain<void>();
      expect(library.listWorks().single.title, 'Manuell korrigierter Titel');
      expect(library.listWorks().single.authors, [
        'Erste Autorin',
        'Zweiter Autor',
      ]);
      expect(library.listWorks().single.series, 'Neue Serie');
      expect(library.listWorks().single.language, 'de');
      library.close();

      await File('${root.path}/.library/index.db').delete();
      final rebuilt = await FundusLibrary.open(root);
      addTearDown(rebuilt.close);
      await rebuilt.index().drain<void>();
      final restored = rebuilt.listWorks().single;
      expect(restored.id, original.id);
      expect(restored.title, 'Manuell korrigierter Titel');
      expect(restored.subtitle, 'Eine Unterzeile');
      expect(restored.authors, ['Erste Autorin', 'Zweiter Autor']);
      expect(restored.series, 'Neue Serie');
      expect(restored.seriesSequence, 2.5);
      expect(restored.narrators, ['Sprecher Eins', 'Sprecher Zwei']);
      expect(restored.publisher, 'Testverlag');
      expect(restored.publishedYear, 2026);
      expect(
        restored.metadataOrigins['title']?.source,
        WorkMetadataSource.user,
      );
      final sidecar = await File(
        '${book.path}/_fundus/meta.yaml',
      ).readAsString();
      expect(sidecar, contains('"field_sources"'));
      expect(sidecar, contains('"source": "user"'));
    },
  );

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
    await library.addMediaBookmark(
      workId: work.id,
      fileId: track.fileId,
      position: MediaPosition(
        kind: MediaPositionKind.imageIndex,
        numericValue: 7,
        total: 24,
        fileId: track.fileId,
        chapterId: 'Kapitel 2',
        elementId: 'pages/007.webp',
        scrollOffset: .35,
        label: 'Kapitel 2 · Seite 7',
      ),
      label: 'Bild-Lesezeichen',
    );

    final annotations = library.loadAnnotations(work.id);
    expect(annotations.tags, ['Fantasy', 'Favorit']);
    expect(annotations.notes, hasLength(2));
    expect(annotations.notes.first.markdown, 'Zweite Notiz');
    expect(
      annotations.bookmarks
          .firstWhere(
            (bookmark) => bookmark.mediaPosition.kind == MediaPositionKind.time,
          )
          .position,
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
    final restoredPageBookmark = restored.bookmarks.firstWhere(
      (bookmark) => bookmark.mediaPosition.kind == MediaPositionKind.imageIndex,
    );
    expect(restoredPageBookmark.mediaPosition.numericValue, 7);
    expect(restoredPageBookmark.mediaPosition.total, 24);
    expect(restoredPageBookmark.mediaPosition.chapterId, 'Kapitel 2');
    expect(restoredPageBookmark.mediaPosition.elementId, 'pages/007.webp');
    expect(restoredPageBookmark.mediaPosition.scrollOffset, .35);
    expect(restoredPageBookmark.displayPosition, 'Bild 7');
    expect(restored.notes, hasLength(2));
    expect(
      restored.notes.map((note) => note.markdown),
      contains('Zweite Notiz'),
    );
    final restoredTimeBookmark = restored.bookmarks.firstWhere(
      (bookmark) => bookmark.mediaPosition.kind == MediaPositionKind.time,
    );
    expect(restoredTimeBookmark.label, 'Wichtige Stelle');
    expect(
      restoredTimeBookmark.position,
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
      expect(metadata, contains('"format_version": 3'));
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

  test('indexes a mixed TTRPG product as one non-audio work', () async {
    final root = await Directory.systemTemp.createTemp('fundus-ttrpg-');
    addTearDown(() => root.delete(recursive: true));
    final product = Directory('${root.path}/TTRPG/Dragonlance');
    await Directory('${product.path}/Maps').create(recursive: true);
    await Directory('${product.path}/Handouts').create(recursive: true);
    await File('${product.path}/Regelwerk.pdf').writeAsBytes([1, 2, 3]);
    await File('${product.path}/Maps/Ansalon.jpg').writeAsBytes([4, 5]);
    await File('${product.path}/Handouts/Brief.png').writeAsBytes([6]);
    await File('${product.path}/cover.jpg').writeAsBytes([7]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    final events = await library.index().toList();
    final work = library.listWorks().single;

    expect(events.last.workCount, 1);
    expect(work.kind, 'ttrpg_product');
    expect(work.title, 'Dragonlance');
    expect(work.fileCount, 4);
    expect(work.coverPath, endsWith('cover.jpg'));
    expect(library.workDirectoryPath(work.id), product.path);
    expect(
      library.playbackTracks(work.id).map((file) => file.title),
      containsAll(['Regelwerk.pdf', 'Ansalon.jpg', 'Brief.png', 'cover.jpg']),
    );
  });

  test(
    'loose document annotations do not treat the file as a directory',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-document-');
      addTearDown(() => root.delete(recursive: true));
      final documents = Directory('${root.path}/Documents');
      await documents.create(recursive: true);
      final file = File('${documents.path}/Wichtige Datei.pdf');
      await file.writeAsBytes([1, 2, 3]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();
      final work = library.listWorks().single;
      final annotations = await library.replaceWorkTags(work.id, ['Wichtig']);

      expect(work.kind, 'document');
      expect(library.workDirectoryPath(work.id), documents.path);
      expect(annotations.tags, ['Wichtig']);
      expect(await file.exists(), isTrue);
      expect(await Directory('${file.path}/_fundus').exists(), isFalse);
    },
  );

  test(
    'stores generic comic page progress without converting it to time',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-comic-');
      addTearDown(() => root.delete(recursive: true));
      final documents = Directory('${root.path}/Documents');
      await documents.create(recursive: true);
      await File('${documents.path}/Comic.cbz').writeAsBytes([1, 2, 3]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();
      final work = library.listWorks().single;
      final track = library.playbackTracks(work.id).single;

      final saved = library.saveMediaProgress(
        workId: work.id,
        fileId: track.fileId,
        position: MediaPosition(
          kind: MediaPositionKind.imageIndex,
          numericValue: 7,
          total: 24,
          fileId: track.fileId,
          chapterId: 'chapter-1',
          elementId: 'pages/007.webp',
          scrollOffset: .25,
          label: 'Seite 7',
        ),
        operationId: 'comic-page-7',
      );

      expect(saved.position.kind, MediaPositionKind.imageIndex);
      expect(saved.position.numericValue, 7);
      expect(saved.position.total, 24);
      expect(saved.position.label, 'Seite 7');
      expect(saved.position.chapterId, 'chapter-1');
      expect(saved.position.elementId, 'pages/007.webp');
      expect(saved.position.scrollOffset, .25);
      expect(library.loadProgress(work.id)?.position.displayValue, 'Bild 7');

      library.saveMediaProgress(
        workId: work.id,
        fileId: track.fileId,
        position: MediaPosition(
          kind: MediaPositionKind.imageIndex,
          numericValue: 8,
          total: 24,
          fileId: track.fileId,
          chapterId: 'chapter-1',
          elementId: 'pages/008.webp',
        ),
        operationId: 'comic-page-8',
      );
      final restored = library.restoreProgressRevision(
        workId: work.id,
        revision: 1,
        operationId: 'restore-comic-page-7',
      );
      expect(restored.position.kind, MediaPositionKind.imageIndex);
      expect(restored.position.elementId, 'pages/007.webp');
      expect(restored.position.scrollOffset, .25);
    },
  );

  test('indexes a manga folder with CBZ chapters and a cover', () async {
    final root = await Directory.systemTemp.createTemp('fundus-manga-');
    addTearDown(() => root.delete(recursive: true));
    final manga = Directory('${root.path}/Manga/Rebirth');
    await manga.create(recursive: true);
    await File('${manga.path}/cover.png').writeAsBytes([1, 2, 3]);
    await File(
      '${manga.path}/Rebirth - Kapitel 0280.cbz',
    ).writeAsBytes([1, 2, 3]);
    await File(
      '${manga.path}/Rebirth - Kapitel 0281.cbz',
    ).writeAsBytes([1, 2, 3]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final work = library.listWorks().single;
    expect(work.kind, 'manga');
    expect(work.title, 'Rebirth');
    expect(work.fileCount, 3);
    expect(work.coverPath, endsWith('cover.png'));
    expect(library.workDirectoryPath(work.id), manga.path);
    expect(
      library.playbackTracks(work.id).map((file) => file.title),
      containsAll([
        'cover.png',
        'Rebirth - Kapitel 0280.cbz',
        'Rebirth - Kapitel 0281.cbz',
      ]),
    );

    final chapter = library
        .playbackTracks(work.id)
        .where((file) => file.title.endsWith('0281.cbz'))
        .single;
    library.saveMediaProgress(
      workId: work.id,
      fileId: chapter.fileId,
      position: MediaPosition(
        kind: MediaPositionKind.imageIndex,
        numericValue: 4,
        total: 18,
        fileId: chapter.fileId,
        label: 'Kapitel 2/2 · Seite 4',
      ),
    );
    expect(library.listWorks().single.mediaProgress?.numericValue, 4);
  });

  test('indexes EPUB package metadata and its embedded cover', () async {
    final root = await Directory.systemTemp.createTemp('fundus-epub-');
    addTearDown(() => root.delete(recursive: true));
    final webnovels = Directory('${root.path}/Webnovels');
    await webnovels.create(recursive: true);
    await File(
      '${webnovels.path}/fallback.epub',
    ).writeAsBytes(_epubWithMetadataAndCover());

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();

    final work = library.listWorks().single;
    expect(work.kind, 'webnovel');
    expect(work.title, 'Die Testnovel');
    expect(work.author, 'Erika Beispiel');
    expect(work.authors, ['Erika Beispiel']);
    expect(work.language, 'de');
    expect(work.description, 'Eine sichere Testbeschreibung.');
    expect(work.genres, ['Fantasy']);
    expect(work.publisher, 'Fundus Testverlag');
    expect(work.coverPath, isNotNull);
    expect(work.coverPath, contains('.library/covers'));
    expect(work.coverPath, endsWith('.png'));
    expect(await File(work.coverPath!).readAsBytes(), _tinyPng);

    final epub = library
        .playbackTracks(work.id)
        .where((file) => file.relativePath.endsWith('.epub'))
        .single;
    final annotations = await library.addTextHighlight(
      workId: work.id,
      fileId: epub.fileId,
      position: MediaPosition(
        kind: MediaPositionKind.epubCfi,
        numericValue: 42,
        fileId: epub.fileId,
        chapterId: 'chapter-1',
        elementId: 'paragraph-example-1',
        scrollOffset: .25,
        label: 'Kapitel 1 · 25 %',
      ),
      quote: 'Ein wichtiges Zitat',
      color: '#90CAF9',
      note: 'Für später',
    );
    expect(annotations.highlights, hasLength(1));
    expect(annotations.bookmarks, isEmpty);
    expect(annotations.highlights.single.quote, 'Ein wichtiges Zitat');
    expect(annotations.highlights.single.color, '#90CAF9');
    expect(
      annotations.highlights.single.mediaPosition.elementId,
      'paragraph-example-1',
    );
    await library.saveWorkNote(work.id, '## Portable EPUB-Notiz');
    await library.replaceWorkTags(work.id, const ['Favorit', 'Fantasy']);
    await library.savePortableReaderProfile(
      workId: work.id,
      deviceKey: 'android',
      readerKind: 'epub',
      profile: const {'font_size': 22.0, 'content_width': 680.0},
    );
    final portableProfile = await library.loadPortableReaderProfile(
      workId: work.id,
      deviceKey: 'android',
      readerKind: 'epub',
    );
    expect(portableProfile?['font_size'], 22.0);
    final sidecar = Directory('${webnovels.path}/_fundus/files/fallback.epub');
    expect(
      await File('${sidecar.path}/notes.md').readAsString(),
      contains('Portable EPUB-Notiz'),
    );
    expect(
      await File('${sidecar.path}/bookmarks.yaml').readAsString(),
      contains('Ein wichtiges Zitat'),
    );
    expect(await File('${sidecar.path}/reader-settings.yaml').exists(), isTrue);
    final markdown = exportAnnotationsAsMarkdown(
      workTitle: work.title,
      annotations: annotations,
    );
    final json = exportAnnotationsAsJson(
      workId: work.id,
      workTitle: work.title,
      annotations: annotations,
    );
    expect(markdown, contains('> Ein wichtiges Zitat'));
    expect(json, contains('"color": "#90CAF9"'));
  });

  test(
    'keeps EPUB and cover together in a series-style Webnovel folder',
    () async {
      final root = await Directory.systemTemp.createTemp('fundus-webnovel-');
      addTearDown(() => root.delete(recursive: true));
      final story = Directory('${root.path}/Webnovels/Die Testserie');
      await story.create(recursive: true);
      await File(
        '${story.path}/Die Testserie.epub',
      ).writeAsBytes(_epubWithMetadataAndCover());
      await File('${story.path}/cover.webp').writeAsBytes([1, 2, 3, 4]);

      final library = await FundusLibrary.create(root);
      addTearDown(library.close);
      await library.index().drain<void>();

      final work = library.listWorks().single;
      final files = library.playbackTracks(work.id);
      expect(work.kind, 'webnovel');
      expect(work.coverPath, endsWith('cover.webp'));
      expect(
        files.map((file) => file.title),
        containsAll(['cover.webp', 'Die Testserie.epub']),
      );
    },
  );

  test('stores a generated document cover inside the library', () async {
    final root = await Directory.systemTemp.createTemp('fundus-pdf-cover-');
    addTearDown(() => root.delete(recursive: true));
    final documents = Directory('${root.path}/Documents');
    await documents.create(recursive: true);
    await File('${documents.path}/Manual.pdf').writeAsBytes([1, 2, 3]);

    final library = await FundusLibrary.create(root);
    addTearDown(library.close);
    await library.index().drain<void>();
    final work = library.listWorks().single;

    final coverPath = await library.cacheGeneratedCover(
      workId: work.id,
      bytes: Uint8List.fromList([9, 8, 7]),
    );

    expect(coverPath, contains('.library/covers'));
    expect(await File(coverPath).readAsBytes(), [9, 8, 7]);
    expect(library.listWorks().single.coverPath, coverPath);
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

final _tinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

List<int> _epubWithMetadataAndCover() {
  final archive = Archive()
    ..addFile(ArchiveFile.string('mimetype', 'application/epub+zip'))
    ..addFile(
      ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/content.opf',
        '''<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book-id" xmlns="http://www.idpf.org/2007/opf">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="book-id">urn:uuid:fundus-library-test</dc:identifier>
    <dc:title>Die Testnovel</dc:title>
    <dc:creator>Erika Beispiel</dc:creator>
    <dc:language>de</dc:language>
    <dc:subject>Fantasy</dc:subject>
    <dc:publisher>Fundus Testverlag</dc:publisher>
    <dc:description>Eine sichere Testbeschreibung.</dc:description>
    <meta name="cover" content="cover"/>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="cover" href="Images/cover.png" media-type="image/png"/>
    <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="chapter"/></spine>
</package>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/toc.ncx',
        '''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:fundus-library-test"/></head>
  <docTitle><text>Die Testnovel</text></docTitle>
  <navMap><navPoint id="chapter" playOrder="1">
    <navLabel><text>Kapitel Eins</text></navLabel>
    <content src="Text/chapter.xhtml"/>
  </navPoint></navMap>
</ncx>''',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'OEBPS/Text/chapter.xhtml',
        '<html><body><p>Der erste Absatz.</p></body></html>',
      ),
    )
    ..addFile(ArchiveFile('OEBPS/Images/cover.png', _tinyPng.length, _tinyPng));
  return ZipEncoder().encode(archive);
}

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
