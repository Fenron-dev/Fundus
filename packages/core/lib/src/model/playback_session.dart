import 'media_position.dart';

enum RepeatMode { none, one, all }

final class PlaybackSessionItem {
  const PlaybackSessionItem({
    required this.workId,
    required this.fileIds,
    required this.position,
  });

  final String workId;
  final List<String> fileIds;
  final int position;

  Map<String, Object?> toJson() => {
    'work_id': workId,
    'file_ids': fileIds,
    'position': position,
  };
}

final class PlaybackSession {
  const PlaybackSession({
    required this.id,
    required this.items,
    required this.currentIndex,
    required this.currentPosition,
    required this.repeatMode,
    required this.shuffleOrder,
    this.playlistId,
    this.playlistRevision,
  });

  final String id;
  final String? playlistId;
  final int? playlistRevision;
  final List<PlaybackSessionItem> items;
  final int currentIndex;
  final MediaPosition currentPosition;
  final RepeatMode repeatMode;
  final List<int> shuffleOrder;

  PlaybackSessionItem get currentItem => items[currentIndex];

  void validate() {
    if (items.isEmpty) {
      throw StateError('Eine Sitzung benötigt mindestens einen Eintrag.');
    }
    if (currentIndex < 0 || currentIndex >= items.length) {
      throw RangeError.index(currentIndex, items, 'currentIndex');
    }
    if (shuffleOrder.isNotEmpty) {
      final expected = List<int>.generate(items.length, (index) => index)
        ..sort();
      final actual = [...shuffleOrder]..sort();
      if (actual.length != expected.length ||
          !actual.indexed.every((entry) => entry.$2 == expected[entry.$1])) {
        throw StateError('Shuffle-Reihenfolge ist keine gültige Permutation.');
      }
    }
  }
}
