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

  testWidgets('medium shell does not render the fixed detail panel', (
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
  });

  testWidgets('regular start offers portable library actions', (tester) async {
    await tester.pumpWidget(const FundusApp());
    await tester.pumpAndSettle();

    expect(find.text('Bibliothek anlegen'), findsOneWidget);
    expect(find.text('Bibliothek öffnen'), findsOneWidget);
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
        fileCount: 1,
        addedAt: DateTime(2026),
      ),
    ];

    await tester.pumpWidget(FundusApp(initialWorks: works));
    await tester.pumpAndSettle();

    expect(find.text('Autor: Aaron Oster'), findsOneWidget);
    expect(find.text('Serie: Master of Monster Arts · Band 1'), findsOneWidget);
    expect(find.text('#Abenteuer'), findsNothing);
    expect(find.text('Versammlung der Apachen'), findsNothing);
    expect(find.text('Noch keine Tags vergeben.'), findsOneWidget);
  });
}
