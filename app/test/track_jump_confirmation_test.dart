import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/track_jump_confirmation.dart';

void main() {
  testWidgets('track jump requires explicit confirmation', (tester) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await confirmPlaybackTrackJump(
                context,
                currentTitle: 'Teil 4',
                targetTitle: 'Teil 12',
                currentPosition: const Duration(
                  hours: 2,
                  minutes: 3,
                  seconds: 4,
                ),
              );
            },
            child: const Text('Datei wählen'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Datei wählen'));
    await tester.pumpAndSettle();
    expect(find.text('Zu einer anderen Datei springen?'), findsOneWidget);
    expect(find.textContaining('02:03:04'), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
