import '../model/fundus_id.dart';
import '../search/library_work_query.dart';

final class LibrarySavedView {
  const LibrarySavedView({
    required this.id,
    required this.name,
    required this.query,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final LibraryWorkQuery query;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'query': query.toJson(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static LibrarySavedView create(String name, LibraryWorkQuery query) =>
      LibrarySavedView(
        id: FundusId.generate(),
        name: name.trim(),
        query: query,
        updatedAt: DateTime.now().toUtc(),
      );

  static LibrarySavedView? fromJson(Object? value) {
    if (value is! Map || value['id'] is! String || value['name'] is! String) {
      return null;
    }
    final updatedAt = DateTime.tryParse('${value['updated_at'] ?? ''}');
    if (updatedAt == null || (value['name'] as String).trim().isEmpty) {
      return null;
    }
    return LibrarySavedView(
      id: value['id'] as String,
      name: (value['name'] as String).trim(),
      query: LibraryWorkQuery.fromJson(value['query']),
      updatedAt: updatedAt.toUtc(),
    );
  }
}
