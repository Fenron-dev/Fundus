import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/work_content_list.dart';

void main() {
  testWidgets('content tile shows read and offline state consistently', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkContentListTile(
            item: const WorkContentItemViewModel(
              id: 'chapter-4',
              title: 'Kapitel 4',
              number: 4,
              readState: DocumentChapterReadState.read,
              availability: WorkContentAvailability.offline,
            ),
            onTap: () {},
          ),
        ),
      ),
    );

    expect(find.text('Kapitel 4'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.download_done), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('remote content remains distinguishable from local content', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WorkContentListTile(
            item: WorkContentItemViewModel(
              id: 'remote-1',
              title: 'Remote-Kapitel',
              number: 1,
              readState: DocumentChapterReadState.unread,
              availability: WorkContentAvailability.remote,
            ),
            onTap: null,
          ),
        ),
      ),
    );

    expect(find.text('1'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });
}
