import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/work_detail_facts.dart';
import 'package:fundus/library/work_detail_view_model.dart';
import 'package:fundus/server/fundus_remote_client.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  testWidgets('shared facts show remote source, availability and progress', (
    tester,
  ) async {
    final detail = WorkDetailViewModel.fromRemote(
      const FundusRemoteWork(
        id: 'work',
        title: 'Novel',
        authors: ['Autorin'],
        hasCover: true,
        kind: 'webnovel',
        fileCount: 3,
      ),
      serverId: 'server',
      libraryId: 'library',
      serverName: 'MacBook',
      libraryName: 'Webnovels',
      offlineAvailable: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              WorkDetailFacts(
                detail: detail,
                progress: const MediaPosition(
                  kind: MediaPositionKind.page,
                  numericValue: 5,
                  total: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('MacBook · Webnovels'), findsOneWidget);
    expect(find.text('Remote · offline verfügbar'), findsOneWidget);
    expect(find.text('Seite 5 · 50 %'), findsOneWidget);
    expect(find.text('3 Datei(en)'), findsOneWidget);
  });

  testWidgets('shared facts distinguish incomplete offline content', (
    tester,
  ) async {
    final detail = WorkDetailViewModel.fromLibrary(
      LibraryWorkSummary(
        id: 'offline',
        kind: 'manga',
        title: 'Manga',
        author: 'Autor',
        fileCount: 20,
        addedAt: DateTime.utc(2026, 8, 26),
        status: 'incomplete',
        offline: true,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WorkDetailFacts(detail: detail)),
      ),
    );

    expect(detail.origin, WorkDetailOrigin.offline);
    expect(find.text('Offline · unvollständig'), findsOneWidget);
  });
}
