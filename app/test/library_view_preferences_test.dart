import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/library_view_preferences.dart';

void main() {
  test('view preferences round-trip all shell values', () {
    const original = LibraryViewPreferences(
      layout: 'table',
      gridTileExtent: 312,
      sidebarCollapsed: true,
      detailPaneVisible: false,
      leftPaneWidth: 390,
      detailPaneWidth: 700,
    );

    final restored = LibraryViewPreferences.fromJson(original.toJson());

    expect(restored.layout, 'table');
    expect(restored.gridTileExtent, 312);
    expect(restored.sidebarCollapsed, isTrue);
    expect(restored.detailPaneVisible, isFalse);
    expect(restored.leftPaneWidth, 390);
    expect(restored.detailPaneWidth, 700);
  });

  test('invalid and legacy values are normalized safely', () {
    final preferences = LibraryViewPreferences.fromJson({
      'layout': 'unknown',
      'grid_tile_extent': 9999,
      'left_pane_width': 1,
      'detail_pane_width': 9999,
      'sidebar_collapsed': true,
    });

    expect(preferences.layout, 'grid');
    expect(preferences.gridTileExtent, 360);
    expect(preferences.leftPaneWidth, 180);
    expect(preferences.detailPaneWidth, 760);
    expect(preferences.sidebarCollapsed, isTrue);
    expect(preferences.detailPaneVisible, isTrue);
  });
}
