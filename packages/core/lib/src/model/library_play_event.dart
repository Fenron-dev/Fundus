/// A durable, device-local playback interval for a work.
///
/// Play events intentionally are not part of the synchronised catalog. They
/// describe the local listening/viewing history of a device and can therefore
/// be retained even when a source is temporarily offline.
final class LibraryPlayEvent {
  const LibraryPlayEvent({
    required this.id,
    required this.workId,
    required this.startedAt,
    required this.secondsPlayed,
    required this.deviceId,
    this.userId = 'default',
    this.endedAt,
  });

  final String id;
  final String workId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int secondsPlayed;
  final String deviceId;
  final String userId;

  bool get isOpen => endedAt == null;

  LibraryPlayEvent copyWith({
    DateTime? endedAt,
    int? secondsPlayed,
  }) => LibraryPlayEvent(
    id: id,
    workId: workId,
    startedAt: startedAt,
    endedAt: endedAt ?? this.endedAt,
    secondsPlayed: secondsPlayed ?? this.secondsPlayed,
    deviceId: deviceId,
    userId: userId,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'work_id': workId,
    'started_at': startedAt.toUtc().toIso8601String(),
    if (endedAt != null) 'ended_at': endedAt!.toUtc().toIso8601String(),
    'seconds_played': secondsPlayed,
    'device_id': deviceId,
    'user_id': userId,
  };

  static LibraryPlayEvent? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['work_id'] is! String ||
        value['started_at'] is! String ||
        value['seconds_played'] is! num ||
        value['device_id'] is! String) {
      return null;
    }
    final startedAt = DateTime.tryParse(value['started_at'] as String);
    if (startedAt == null) return null;
    final endedAtValue = value['ended_at'];
    final endedAt = endedAtValue == null
        ? null
        : DateTime.tryParse('$endedAtValue');
    if (endedAtValue != null && endedAt == null) return null;
    final secondsPlayed = (value['seconds_played'] as num).toInt();
    if (secondsPlayed < 0) return null;
    return LibraryPlayEvent(
      id: value['id'] as String,
      workId: value['work_id'] as String,
      startedAt: startedAt.toUtc(),
      endedAt: endedAt?.toUtc(),
      secondsPlayed: secondsPlayed,
      deviceId: value['device_id'] as String,
      userId: value['user_id'] is String
          ? value['user_id'] as String
          : 'default',
    );
  }
}
