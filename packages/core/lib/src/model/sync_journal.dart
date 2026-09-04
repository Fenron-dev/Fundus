import 'dart:convert';

/// A durable, idempotent change that can be exchanged between Fundus sources.
///
/// Journal entries deliberately carry a JSON payload instead of exposing
/// SQLite rows. This keeps the wire protocol stable while allowing new
/// synchronisable entities to be added independently.
final class LibrarySyncJournalEntry {
  const LibrarySyncJournalEntry({
    required this.sequence,
    required this.entity,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.revision,
    required this.deviceId,
    required this.operationId,
    required this.createdAt,
  });

  final int sequence;
  final String entity;
  final String entityId;
  final String operation;
  final Map<String, Object?> payload;
  final int revision;
  final String deviceId;
  final String operationId;
  final DateTime createdAt;

  bool get isDelete => operation == 'delete';

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'entity': entity,
    'entity_id': entityId,
    'op': operation,
    'payload': payload,
    'revision': revision,
    'device_id': deviceId,
    'operation_id': operationId,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  static LibrarySyncJournalEntry? fromJson(Object? value) {
    if (value is! Map ||
        value['entity'] is! String ||
        value['entity_id'] is! String ||
        value['op'] is! String ||
        value['payload'] is! Map ||
        value['revision'] is! num ||
        value['device_id'] is! String ||
        value['operation_id'] is! String) {
      return null;
    }
    final operation = value['op'] as String;
    if (operation != 'upsert' && operation != 'delete') return null;
    final createdAt = DateTime.tryParse('${value['created_at'] ?? ''}');
    if (createdAt == null) return null;
    return LibrarySyncJournalEntry(
      sequence: value['sequence'] is num
          ? (value['sequence'] as num).toInt()
          : 0,
      entity: value['entity'] as String,
      entityId: value['entity_id'] as String,
      operation: operation,
      payload: Map<String, Object?>.from(value['payload'] as Map),
      revision: (value['revision'] as num).toInt(),
      deviceId: value['device_id'] as String,
      operationId: value['operation_id'] as String,
      createdAt: createdAt.toUtc(),
    );
  }

  /// Canonical payload encoding used when an entry is persisted.
  String get payloadJson => jsonEncode(payload);
}

final class LibrarySyncApplyResult {
  const LibrarySyncApplyResult({required this.applied, required this.ignored});

  final int applied;
  final int ignored;
}
