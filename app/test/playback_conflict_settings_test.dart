import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playback_conflict_settings.dart';

void main() {
  testWidgets('shows devices, chapters, percentages and restores history', (
    tester,
  ) async {
    PlaybackProgressRevisionView? restored;
    final conflict = PlaybackResumeConflict(
      currentPosition: const Duration(minutes: 15),
      incomingPosition: const Duration(minutes: 30),
      currentDuration: const Duration(hours: 1),
      incomingDuration: const Duration(hours: 1),
      currentTrack: '01 - Auftakt.mp3',
      incomingTrack: '02 - Reise.mp3',
      currentChapter: 'Aufbruch',
      incomingChapter: 'Die Grenze',
      currentDevice: 'Dennis Pixel',
      incomingDevice: 'MacBook Arbeitszimmer',
      incomingSource: 'Fundus Zuhause',
      loadHistory: () async => [
        PlaybackProgressRevisionView(
          revision: 4,
          position: const Duration(minutes: 10),
          duration: const Duration(hours: 1),
          track: '01 - Auftakt.mp3',
          chapter: 'Vorbereitung',
          deviceName: 'Tablet',
          createdAt: DateTime(2026, 8, 11, 12, 34),
        ),
      ],
      restoreRevision: (revision) async => restored = revision,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => PlaybackConflictDialog(conflict: conflict),
              ),
              child: const Text('Konflikt öffnen'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Konflikt öffnen'));
    await tester.pumpAndSettle();

    expect(find.text('Dennis Pixel'), findsOneWidget);
    expect(find.text('MacBook Arbeitszimmer'), findsOneWidget);
    expect(find.text('Kapitel: Aufbruch'), findsOneWidget);
    expect(find.text('Kapitel: Die Grenze'), findsOneWidget);
    expect(find.text('00:15:00 / 01:00:00 · 25 %'), findsOneWidget);
    expect(find.text('00:30:00 / 01:00:00 · 50 %'), findsOneWidget);

    await tester.tap(find.text('Verlauf'));
    await tester.pumpAndSettle();

    expect(find.text('Hörstand-Verlauf'), findsOneWidget);
    expect(
      find.text('Tablet · 01 - Auftakt.mp3 · Vorbereitung · 11.08.2026 12:34'),
      findsOneWidget,
    );
    expect(find.text('00:10:00 / 01:00:00 · 17 %'), findsOneWidget);

    await tester.tap(find.text('Wiederherstellen'));
    await tester.pumpAndSettle();

    expect(restored?.revision, 4);
    expect(find.text('Abweichender Hörstand gefunden'), findsNothing);
  });
}
