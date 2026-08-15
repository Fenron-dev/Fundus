import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('time positions have a comparable human readable value', () {
    const position = MediaPosition(
      kind: MediaPositionKind.time,
      numericValue: 5792,
      total: 7200,
      label: 'Kapitel 7',
    );

    expect(position.displayValue, '01:36:32');
    expect(position.fraction, closeTo(0.8044, 0.0001));
  });

  test('page positions include the page number', () {
    const position = MediaPosition(
      kind: MediaPositionKind.page,
      numericValue: 42,
      total: 300,
    );

    expect(position.displayValue, 'Seite 42');
  });

  test(
    'versioned publication anchors round-trip and legacy data remains valid',
    () {
      const position = MediaPosition(
        kind: MediaPositionKind.imageIndex,
        numericValue: 12,
        total: 18,
        fileId: 'chapter-file',
        chapterId: 'chapter-283',
        elementId: 'pages/012.webp',
        scrollOffset: .35,
        label: 'Kapitel 283 · Seite 12',
      );

      final restored = MediaPosition.fromJson(position.toJson());
      expect(restored.schemaVersion, MediaPosition.currentSchemaVersion);
      expect(restored.chapterId, 'chapter-283');
      expect(restored.elementId, 'pages/012.webp');
      expect(restored.scrollOffset, .35);
      final rebound = restored.withFileId('moved-chapter-file');
      expect(rebound.fileId, 'moved-chapter-file');
      expect(rebound.elementId, restored.elementId);
      expect(rebound.scrollOffset, restored.scrollOffset);

      final legacy = MediaPosition.fromJson({
        'kind': 'page',
        'numeric_value': 4,
      });
      expect(legacy.schemaVersion, 1);
      expect(legacy.displayValue, 'Seite 4');
    },
  );

  test('future versions and invalid offsets are rejected', () {
    expect(
      () => MediaPosition.fromJson({
        'schema_version': MediaPosition.currentSchemaVersion + 1,
        'kind': 'page',
        'numeric_value': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => MediaPosition.fromJson({
        'kind': 'page',
        'numeric_value': 1,
        'scroll_offset': 1.2,
      }),
      throwsFormatException,
    );
  });
}
