enum MediaPositionKind { time, page, epubCfi, imageIndex }

final class MediaPosition {
  const MediaPosition({
    required this.kind,
    this.schemaVersion = currentSchemaVersion,
    this.numericValue,
    this.key,
    this.total,
    this.fileId,
    this.chapterId,
    this.elementId,
    this.scrollOffset,
    this.label,
  }) : assert(numericValue != null || key != null),
       assert(schemaVersion > 0 && schemaVersion <= currentSchemaVersion),
       assert(scrollOffset == null || scrollOffset >= 0 && scrollOffset <= 1);

  static const currentSchemaVersion = 2;

  final MediaPositionKind kind;
  final int schemaVersion;
  final double? numericValue;
  final String? key;
  final double? total;
  final String? fileId;
  final String? chapterId;
  final String? elementId;

  /// Normalized position inside a continuous page or chapter (0..1).
  final double? scrollOffset;
  final String? label;

  double? get fraction {
    final value = numericValue;
    final maximum = total;
    if (value == null || maximum == null || maximum <= 0) return null;
    return (value / maximum).clamp(0, 1);
  }

  String get displayValue {
    return switch (kind) {
      MediaPositionKind.time => _formatDuration(numericValue ?? 0),
      MediaPositionKind.page => 'Seite ${(numericValue ?? 0).round()}',
      MediaPositionKind.imageIndex => 'Bild ${(numericValue ?? 0).round()}',
      MediaPositionKind.epubCfi => label ?? 'EPUB-Position',
    };
  }

  MediaPosition withFileId(String? value) => MediaPosition(
    kind: kind,
    schemaVersion: schemaVersion,
    numericValue: numericValue,
    key: key,
    total: total,
    fileId: value,
    chapterId: chapterId,
    elementId: elementId,
    scrollOffset: scrollOffset,
    label: label,
  );

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'kind': kind.name,
    'numeric_value': numericValue,
    'key': key,
    'total': total,
    'file_id': fileId,
    'chapter_id': chapterId,
    'element_id': elementId,
    'scroll_offset': scrollOffset,
    'label': label,
  };

  factory MediaPosition.fromJson(Map<String, Object?> json) {
    final version = json['schema_version'] as int? ?? 1;
    if (version < 1 || version > currentSchemaVersion) {
      throw FormatException('Nicht unterstützte Positionsversion: $version.');
    }
    final scrollOffset = (json['scroll_offset'] as num?)?.toDouble();
    if (scrollOffset != null &&
        (!scrollOffset.isFinite || scrollOffset < 0 || scrollOffset > 1)) {
      throw const FormatException('Ungültiger normalisierter Scroll-Offset.');
    }
    return MediaPosition(
      schemaVersion: version,
      kind: MediaPositionKind.values.byName(json['kind']! as String),
      numericValue: (json['numeric_value'] as num?)?.toDouble(),
      key: json['key'] as String?,
      total: (json['total'] as num?)?.toDouble(),
      fileId: json['file_id'] as String?,
      chapterId: json['chapter_id'] as String?,
      elementId: json['element_id'] as String?,
      scrollOffset: scrollOffset,
      label: json['label'] as String?,
    );
  }

  static String _formatDuration(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final remaining = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$remaining';
  }
}
