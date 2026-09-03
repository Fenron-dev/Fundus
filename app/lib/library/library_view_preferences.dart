import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Device-local preferences shared by every library source (local, remote and
/// offline).  Keeping these values outside a vault means a vault can be
/// replaced or temporarily unavailable without resetting the user's layout.
final class LibraryViewPreferences {
  const LibraryViewPreferences({
    this.layout = 'grid',
    this.gridTileExtent = 220,
    this.sidebarCollapsed = false,
    this.detailPaneVisible = true,
    this.leftPaneWidth = 236,
    this.detailPaneWidth = 480,
  });

  final String layout;
  final double gridTileExtent;
  final bool sidebarCollapsed;
  final bool detailPaneVisible;
  final double leftPaneWidth;
  final double detailPaneWidth;

  LibraryViewPreferences copyWith({
    String? layout,
    double? gridTileExtent,
    bool? sidebarCollapsed,
    bool? detailPaneVisible,
    double? leftPaneWidth,
    double? detailPaneWidth,
  }) {
    return LibraryViewPreferences(
      layout: _normalizeLayout(layout ?? this.layout),
      gridTileExtent: _clamp(gridTileExtent ?? this.gridTileExtent, 140, 360),
      sidebarCollapsed: sidebarCollapsed ?? this.sidebarCollapsed,
      detailPaneVisible: detailPaneVisible ?? this.detailPaneVisible,
      leftPaneWidth: _clamp(leftPaneWidth ?? this.leftPaneWidth, 180, 420),
      detailPaneWidth: _clamp(
        detailPaneWidth ?? this.detailPaneWidth,
        420,
        760,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'layout': layout,
    'grid_tile_extent': gridTileExtent,
    'sidebar_collapsed': sidebarCollapsed,
    'detail_pane_visible': detailPaneVisible,
    'left_pane_width': leftPaneWidth,
    'detail_pane_width': detailPaneWidth,
  };

  factory LibraryViewPreferences.fromJson(Map<String, Object?> json) {
    return const LibraryViewPreferences().copyWith(
      layout: json['layout'] is String ? json['layout'] as String : null,
      gridTileExtent: (json['grid_tile_extent'] as num?)?.toDouble(),
      sidebarCollapsed: json['sidebar_collapsed'] as bool?,
      detailPaneVisible: json['detail_pane_visible'] as bool?,
      leftPaneWidth: (json['left_pane_width'] as num?)?.toDouble(),
      detailPaneWidth: (json['detail_pane_width'] as num?)?.toDouble(),
    );
  }

  static String _normalizeLayout(String value) => switch (value) {
    'table' => 'table',
    'folder' => 'folder',
    _ => 'grid',
  };

  static double _clamp(double value, double min, double max) =>
      value.clamp(min, max).toDouble();
}

final class LibraryViewPreferencesStore {
  LibraryViewPreferencesStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'fundus.library.view-preferences.v1';
  final FlutterSecureStorage _storage;
  Future<void> _writes = Future.value();

  Future<LibraryViewPreferences> load() async {
    try {
      await _writes;
      final raw = await _storage.read(key: key);
      if (raw == null || raw.trim().isEmpty) {
        return const LibraryViewPreferences();
      }
      final value = jsonDecode(raw);
      if (value is! Map) return const LibraryViewPreferences();
      return LibraryViewPreferences.fromJson(Map<String, Object?>.from(value));
    } catch (_) {
      // Layout preferences are optional and must never prevent opening a
      // library when secure storage is unavailable.
      return const LibraryViewPreferences();
    }
  }

  Future<void> save(LibraryViewPreferences preferences) {
    final operation = _writes.then((_) async {
      try {
        await _storage.write(key: key, value: jsonEncode(preferences.toJson()));
      } catch (_) {
        // Best effort only; the in-memory setting remains usable.
      }
    });
    _writes = operation;
    return operation;
  }
}
