import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/work_detail_sections.dart';

void main() {
  testWidgets('detail selector exposes the same ordered publication sections', (
    tester,
  ) async {
    var selected = WorkDetailSection.info;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => WorkDetailSectionSelector(
              selected: selected,
              onChanged: (value) => setState(() => selected = value),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Dateien'), findsOneWidget);
    expect(find.text('Kapitel'), findsOneWidget);
    expect(find.text('Notizen'), findsOneWidget);
    expect(find.text('Ähnlich'), findsOneWidget);

    await tester.tap(find.text('Kapitel'));
    await tester.pump();
    expect(selected, WorkDetailSection.chapters);
  });

  testWidgets('annotation selector switches between notes and annotations', (
    tester,
  ) async {
    var selected = WorkAnnotationSection.notes;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => WorkAnnotationSectionSelector(
              selected: selected,
              onChanged: (value) => setState(() => selected = value),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Lesezeichen & Highlights'));
    await tester.pump();
    expect(selected, WorkAnnotationSection.annotations);
  });
}
