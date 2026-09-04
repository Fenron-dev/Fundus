import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Shared media-kit setup for every video origin.
///
/// Local files, remote range streams and offline copies must use the same
/// native-surface lifecycle. Keeping this in one place prevents subtle resume
/// differences (most notably the Android audio-only/black-texture state).
final class FundusVideoPlaybackSession {
  const FundusVideoPlaybackSession._();

  static const VideoControllerConfiguration configuration =
      VideoControllerConfiguration(
        androidAttachSurfaceAfterVideoParameters: true,
      );

  static VideoController createVideoController(Player player) =>
      VideoController(player, configuration: configuration);

  /// Wait until the native decoder has exposed dimensions before seeking a
  /// resumed item. Audio-only files and a few network containers legitimately
  /// never publish video parameters, so the timeout is intentionally soft.
  static Future<void> waitForVideoParameters(
    Player player, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final current = player.state.videoParams;
    if (current.w != null && current.h != null) return;
    try {
      await player.stream.videoParams
          .firstWhere((value) => value.w != null && value.h != null)
          .timeout(timeout);
    } catch (_) {
      // Some audio-only files and remote containers expose no dimensions.
    }
  }
}
