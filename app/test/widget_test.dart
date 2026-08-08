import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/main.dart';
import 'package:fundus_core/fundus_core.dart';

const testWorks = [
  LibraryWorkSummary(
    id: 'work-1',
    kind: 'audiobook',
    title: 'Winnetou I',
    author: 'Karl May',
    series: 'Winnetou',
    fileCount: 2,
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

    await tester.pumpWidget(const FundusApp(initialWorks: testWorks));
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

    await tester.pumpWidget(const FundusApp(initialWorks: testWorks));
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
}
