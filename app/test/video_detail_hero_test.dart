import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/fundus_breadcrumbs.dart';
import 'package:fundus/library/video_detail_hero.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  testWidgets('video hero exposes shared navigation and cover action', (
    tester,
  ) async {
    var favoriteChanged = false;
    var coverOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: FundusVideoDetailHero(
              work: LibraryWorkSummary(
                id: 'video',
                kind: 'tv',
                title: 'Chainsaw Man',
                author: 'Studio',
                fileCount: 12,
                addedAt: DateTime(2026),
                contentStyle: 'anime',
              ),
              breadcrumbs: [
                const FundusBreadcrumb(label: 'Anime'),
                const FundusBreadcrumb(label: 'Chainsaw Man'),
              ],
              coverBuilder: (_) => const ColoredBox(color: Colors.purple),
              favorite: true,
              onToggleFavorite: () => favoriteChanged = true,
              onCoverTap: () => coverOpened = true,
              onOpen: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Chainsaw Man'), findsNWidgets(2));
    expect(find.text('Anime'), findsOneWidget);
    expect(find.text('Anime-Serie'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('video-detail-cover-action')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('video-detail-cover-action')));
    await tester.tap(find.byIcon(Icons.star));
    expect(coverOpened, isTrue);
    expect(favoriteChanged, isTrue);
  });
}
