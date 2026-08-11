import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/main.dart';
import 'package:fundus_core/fundus_core.dart';

final testWorks = [
  LibraryWorkSummary(
    id: 'work-1',
    kind: 'audiobook',
    title: 'Winnetou I',
    author: 'Karl May',
    series: 'Winnetou',
    seriesSequence: 1,
    fileCount: 2,
    addedAt: DateTime(2026),
  ),
  LibraryWorkSummary(
    id: 'work-2',
    kind: 'audiobook',
    title: 'Der Ölprinz',
    author: 'Karl May',
    fileCount: 1,
    addedAt: DateTime(2026, 2),
  ),
];

void main() {
  testWidgets('desktop shell shows library, search and details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FundusApp(initialWorks: testWorks));
    await tester.pumpAndSettle();

    expect(find.text('Fundus'), findsOneWidget);
    expect(find.text('Suchen und filtern …'), findsOneWidget);
    expect(find.text('Weiterhören'), findsOneWidget);
  });

  testWidgets('medium shell keeps navigation and opens details inline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FundusApp(initialWorks: testWorks));
    await tester.pumpAndSettle();

    expect(find.text('Weiterhören'), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);

    await tester.tap(find.text('Winnetou I'));
    await tester.pumpAndSettle();
    expect(find.text('Weiterhören'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byTooltip('Zurück zur Übersicht'), findsOneWidget);
  });

  testWidgets('desktop detail sidebar can be hidden and details open inline', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FundusApp(initialWorks: testWorks));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Detailleiste ausblenden'));
    await tester.pumpAndSettle();

    expect(find.text('Weiterhören'), findsNothing);
    await tester.tap(find.text('Winnetou I'));
    await tester.pumpAndSettle();

    expect(find.text('Weiterhören'), findsOneWidget);
    expect(find.byTooltip('Zurück zur Übersicht'), findsOneWidget);
    expect(find.text('Hörbücher'), findsWidgets);
  });

  testWidgets('playlist card starts playback instead of opening the editor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('fundus-playlist-');
      final book = Directory('${root.path}/Autor/Serie/01 - Titel');
      await book.create(recursive: true);
      await File('${book.path}/Kapitel.mp3').writeAsBytes([1, 2, 3]);
      final library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      final work = library.listWorks().single;
      final playlist = library.savePlaylist(
        name: 'Meine Testliste',
        workIds: [work.id],
        mediaType: 'audiobook',
      );
      return (root: root, library: library, work: work, playlist: playlist);
    });
    final data = setup!;
    addTearDown(() => data.root.delete(recursive: true));
    addTearDown(data.library.close);
    String? startedPlaylist;

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryShell(
          works: [data.work],
          library: data.library,
          onToggleTheme: () {},
          onPlayPlaylist: (id) async => startedPlaylist = id,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Playlists').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Meine Testliste'));
    await tester.pumpAndSettle();

    expect(startedPlaylist, data.playlist.id);
    expect(find.textContaining('verwalten'), findsNothing);
  });

  testWidgets('regular start offers portable library actions', (tester) async {
    await tester.pumpWidget(const FundusApp());
    await tester.pumpAndSettle();

    expect(find.text('Bibliothek anlegen'), findsOneWidget);
    expect(find.text('Bibliothek öffnen'), findsOneWidget);
  });

  testWidgets('mobile shell can return to the library selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var closed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryShell(
          works: testWorks,
          onToggleTheme: () {},
          onClose: () => closed = true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Bibliothek oder Server wechseln'));

    expect(closed, isTrue);
  });

  testWidgets('server settings explain the safe local sharing mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const FundusApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Server & Freigaben').first);
    await tester.pumpAndSettle();

    expect(find.text('Server & Freigaben'), findsWidgets);
    expect(find.text('Server ist aus'), findsOneWidget);
    expect(find.text('Freigegebene Bibliotheken'), findsOneWidget);
    expect(find.textContaining('Ohne LAN-Freigabe'), findsOneWidget);
    expect(find.text('Im lokalen Netzwerk freigeben'), findsOneWidget);
    expect(find.text('Bei abweichendem Hörstand nachfragen'), findsOneWidget);
  });

  testWidgets('desktop search tolerates a misspelled title', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(FundusApp(initialWorks: testWorks));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'Winetu');
    await tester.pump();

    expect(find.text('Winnetou I'), findsWidgets);
    expect(find.text('Der Ölprinz'), findsNothing);
  });

  testWidgets('detail panel uses work metadata instead of demo values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final works = [
      LibraryWorkSummary(
        id: 'monster-arts',
        kind: 'audiobook',
        title: 'Master of Monster Arts',
        author: 'Aaron Oster',
        series: 'Master of Monster Arts',
        seriesSequence: 1,
        coverPath: '/tmp/fundus-test-cover.jpg',
        fileCount: 1,
        progressPosition: const Duration(hours: 1, minutes: 12, seconds: 15),
        progressDuration: const Duration(hours: 12, minutes: 45, seconds: 30),
        addedAt: DateTime(2026),
      ),
    ];

    await tester.pumpWidget(FundusApp(initialWorks: works));
    await tester.pumpAndSettle();

    expect(find.text('Aaron Oster'), findsOneWidget);
    expect(find.text('Master of Monster Arts · Band 1'), findsOneWidget);
    expect(find.text('#Abenteuer'), findsNothing);
    expect(find.text('Versammlung der Apachen'), findsNothing);
    expect(find.text('Noch keine Tags vergeben.'), findsOneWidget);
    expect(find.textContaining('01:12:15 / 12:45:30'), findsWidgets);
    expect(find.textContaining('Rest 11:33:15'), findsWidgets);
    expect(find.byType(Image), findsWidgets);
  });

  testWidgets('narrator chip opens all audiobooks spoken by that person', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final works = [
      LibraryWorkSummary(
        id: 'spoken-one',
        kind: 'audiobook',
        title: 'Das erste Hörbuch',
        author: 'Autor Eins',
        narrators: const ['Stimme Eins'],
        fileCount: 1,
        addedAt: DateTime(2026),
      ),
      LibraryWorkSummary(
        id: 'spoken-two',
        kind: 'audiobook',
        title: 'Ein anderes Hörbuch',
        author: 'Autor Zwei',
        narrators: const ['Stimme Zwei'],
        fileCount: 1,
        addedAt: DateTime(2026),
      ),
    ];

    await tester.pumpWidget(FundusApp(initialWorks: works));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stimme Eins'));
    await tester.pumpAndSettle();

    expect(find.text('Gesprochen von Stimme Eins'), findsOneWidget);
    expect(find.text('Das erste Hörbuch'), findsWidgets);
    expect(find.text('Ein anderes Hörbuch'), findsNothing);
  });

  testWidgets('detail panel renders portable tags and notes', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final setup = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('fundus-widget-');
      final book = Directory('${root.path}/Autor/Serie/01 - Titel');
      await book.create(recursive: true);
      await File('${book.path}/Kapitel.mp3').writeAsBytes([1, 2, 3]);
      final library = await FundusLibrary.create(root);
      await library.index().drain<void>();
      final work = library.listWorks().single;
      await library.replaceWorkTags(work.id, ['Fantasy']);
      await library.saveWorkNote(work.id, 'Meine **Notiz**');
      return (root: root, library: library, work: work);
    });
    final root = setup!.root;
    final library = setup.library;
    final work = setup.work;
    addTearDown(() => root.delete(recursive: true));
    addTearDown(library.close);

    await tester.pumpWidget(
      MaterialApp(
        home: LibraryShell(
          works: [work],
          library: library,
          onToggleTheme: () {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('#Fantasy'), findsOneWidget);
    final detailScroll = find
        .descendant(
          of: find.byKey(const ValueKey('detail-panel-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('Meine **Notiz**'),
      300,
      scrollable: detailScroll,
    );
    expect(find.text('Meine **Notiz**'), findsOneWidget);
    expect(find.textContaining('Uhr'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Notiz speichern'),
      300,
      scrollable: detailScroll,
    );
    expect(find.text('Notiz speichern'), findsOneWidget);
    expect(find.byTooltip('Tag hinzufügen'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('note-input')), 'Neu');
    await tester.tap(find.text('Notiz speichern'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('note-input')),
    );
    expect(input.controller?.text, isEmpty);
  });

  testWidgets('browses from authors through series to books', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(FundusApp(initialWorks: testWorks));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bücher'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nach Autoren'));
    await tester.pumpAndSettle();

    expect(find.text('Karl May'), findsOneWidget);
    await tester.tap(find.text('Karl May'));
    await tester.pumpAndSettle();

    expect(find.text('Winnetou'), findsOneWidget);
    expect(find.text('Einzelbände'), findsOneWidget);
    await tester.tap(find.text('Winnetou'));
    await tester.pumpAndSettle();

    expect(find.text('Winnetou I'), findsWidgets);
    expect(find.text('Band 1'), findsOneWidget);
    expect(find.text('Der Ölprinz'), findsNothing);

    await tester.tap(find.byTooltip('Tabelle'));
    await tester.pumpAndSettle();
    expect(find.text('Sprache'), findsOneWidget);
  });
}
