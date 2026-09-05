import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/video/video_metadata_diff_dialog.dart';
import 'package:fundus_core/fundus_core.dart';

void main() {
  testWidgets('metadata diff defaults to changed fields and can be narrowed', (
    tester,
  ) async {
    VideoMetadataDiffSelection? result;
    final current = LibraryWorkSummary(
      id: 'work',
      kind: 'tv',
      title: 'Old title',
      author: 'Studio',
      description: 'Meine Beschreibung',
      publishedYear: 2020,
      genres: const ['Drama'],
      fileCount: 1,
      addedAt: DateTime(2020),
    );
    const incoming = VideoProviderCandidate(
      provider: 'tmdb',
      providerId: '42',
      title: 'New title',
      description: 'Provider description',
      releaseYear: 2024,
      genres: ['Action'],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showVideoMetadataDiffDialog(
                context,
                current: current,
                incoming: incoming,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('TMDB – Änderungen prüfen'), findsOneWidget);
    expect(find.text('Titel'), findsOneWidget);
    expect(find.text('Beschreibung'), findsOneWidget);
    expect(find.text('Jahr'), findsOneWidget);
    expect(find.text('Genres'), findsOneWidget);

    await tester.tap(find.text('Beschreibung'));
    await tester.tap(find.text('Auswahl übernehmen'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.contains(VideoMetadataField.title), isTrue);
    expect(result!.contains(VideoMetadataField.year), isTrue);
    expect(result!.contains(VideoMetadataField.genres), isTrue);
    expect(result!.contains(VideoMetadataField.description), isFalse);
  });
}
