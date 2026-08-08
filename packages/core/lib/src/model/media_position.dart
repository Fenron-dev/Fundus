enum MediaPositionKind { time, page, epubCfi, imageIndex }

final class MediaPosition {
  const MediaPosition({
    required this.kind,
    this.numericValue,
    this.key,
    this.total,
    this.fileId,
    this.label,
  }) : assert(numericValue != null || key != null);

  final MediaPositionKind kind;
  final double? numericValue;
  final String? key;
  final double? total;
  final String? fileId;
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

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'numeric_value': numericValue,
    'key': key,
    'total': total,
    'file_id': fileId,
    'label': label,
  };

  factory MediaPosition.fromJson(Map<String, Object?> json) {
    return MediaPosition(
      kind: MediaPositionKind.values.byName(json['kind']! as String),
      numericValue: (json['numeric_value'] as num?)?.toDouble(),
      key: json['key'] as String?,
      total: (json['total'] as num?)?.toDouble(),
      fileId: json['file_id'] as String?,
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
