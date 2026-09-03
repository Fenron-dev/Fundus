/// Shared classification helpers for video works.
///
/// The persisted `kind` can be a generic value (`movie`, `tv`, `video`) or a
/// user-facing variant (`anime_tv`, `hhh_movie`, ...). Keeping the mapping in
/// core prevents local, remote and offline clients from accidentally treating
/// a variant as a document and displaying the wrong reader/actions.
abstract final class VideoWorkKind {
  static bool isVideo(String kind) {
    final value = kind.trim().toLowerCase();
    return switch (value) {
      'movie' ||
      'tv' ||
      'video' ||
      'anime_movie' ||
      'anime_tv' ||
      'hhh_movie' ||
      'hhh_tv' => true,
      _ => false,
    };
  }

  /// Returns the generic preference family used for player defaults.
  static String base(String kind) {
    final value = kind.trim().toLowerCase();
    if (value.endsWith('_movie') || value == 'movie') return 'movie';
    if (value.endsWith('_tv') || value == 'tv') return 'tv';
    return value == 'video' ? 'video' : value;
  }
}
