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
}
