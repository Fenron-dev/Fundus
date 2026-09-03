import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/work_detail_header.dart';
import 'package:fundus/library/work_detail_view_model.dart';
import 'package:fundus/server/fundus_remote_client.dart';

void main() {
  testWidgets('shared header exposes publication identity and actions', (
    tester,
  ) async {
    var opened = false;
    var downloaded = false;
    var favoriteChanged = false;
    final detail = WorkDetailViewModel.fromRemote(
      const FundusRemoteWork(
        id: 'work',
        title: 'Remote Manga',
        authors: ['Autorin'],
        hasCover: true,
        kind: 'manga',
        fileCount: 12,
      ),
      serverId: 'server',
      libraryId: 'library',
      offlineAvailable: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkDetailHeader(
              detail: detail,
              coverBuilder: (_) => const ColoredBox(color: Colors.purple),
              favorite: true,
              onToggleFavorite: () => favoriteChanged = true,
              primaryAction: WorkDetailHeaderAction(
                label: 'Fortsetzen',
                icon: Icons.menu_book_outlined,
                onPressed: () => opened = true,
              ),
              secondaryAction: WorkDetailHeaderAction(
                label: 'Kapitel verwalten',
                icon: Icons.download_done,
                onPressed: () => downloaded = true,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Remote Manga'), findsOneWidget);
    expect(find.text('Autorin'), findsOneWidget);
    expect(find.text('Manga/Comic'), findsOneWidget);
    expect(find.text('12 Datei(en)'), findsOneWidget);
    expect(find.text('Offline verfügbar'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('work-detail-primary-action')));
    await tester.tap(
      find.byKey(const ValueKey('work-detail-secondary-action')),
    );
    await tester.tap(find.byKey(const ValueKey('work-detail-favorite-action')));
    expect(opened, isTrue);
    expect(downloaded, isTrue);
    expect(favoriteChanged, isTrue);
  });

  testWidgets('shared header supports local works with a single action', (
    tester,
  ) async {
    final detail = WorkDetailViewModel.fromRemote(
      const FundusRemoteWork(
        id: 'novel',
        title: 'Webnovel',
        authors: [],
        hasCover: false,
        kind: 'webnovel',
        fileCount: 1,
      ),
      serverId: 'server',
      libraryId: 'library',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkDetailHeader(
            detail: detail,
            coverBuilder: (_) => const Icon(Icons.book),
            primaryAction: const WorkDetailHeaderAction(
              label: 'Lesen',
              icon: Icons.menu_book_outlined,
              onPressed: null,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Lesen'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-detail-secondary-action')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('work-detail-favorite-action')),
      findsNothing,
    );
  });

  testWidgets('shared header resolves anime and HHH video labels', (
    tester,
  ) async {
    final anime = WorkDetailViewModel.fromRemote(
      const FundusRemoteWork(
        id: 'anime',
        title: 'Anime-Serie',
        authors: const [],
        hasCover: false,
        kind: 'tv',
        contentStyle: 'anime',
        fileCount: 1,
      ),
      serverId: 'server',
      libraryId: 'library',
    );
    final hhh = WorkDetailViewModel.fromRemote(
      const FundusRemoteWork(
        id: 'hhh',
        title: 'HHH-Serie',
        authors: [],
        hasCover: false,
        kind: 'tv',
        contentSensitivity: 'adult_explicit',
        fileCount: 1,
      ),
      serverId: 'server',
      libraryId: 'library',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkDetailHeader(
            detail: anime,
            coverBuilder: (_) => const Icon(Icons.movie),
          ),
        ),
      ),
    );

    expect(find.text('Anime-Serie'), findsNWidgets(2));
    expect(find.widgetWithText(Chip, 'Anime-Serie'), findsOneWidget);
    expect(find.text('Serie'), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkDetailHeader(
            detail: hhh,
            coverBuilder: (_) => const Icon(Icons.movie),
          ),
        ),
      ),
    );
    expect(find.widgetWithText(Chip, 'HHH-Serie'), findsOneWidget);
  });
}
