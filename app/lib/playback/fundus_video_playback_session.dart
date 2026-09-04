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

  /// Prime the native video surface after the player route has been mounted.
  ///
  /// A player can have a valid clock (and therefore resume audio at the right
  /// timestamp) before the platform texture has received a frame.  Pausing,
  /// seeking once after the surface is attached, and only then starting
  /// playback avoids the audio-only/black-video state seen on resumed files.
  /// The zero-position retry is deliberately limited to one pass so a slow
  /// network stream cannot cause an endless seek loop.
  static Future<bool> primeVideoSurface({
    required Player player,
    required VideoController videoController,
    Duration? target,
    Duration timeout = const Duration(seconds: 3),
    bool Function()? isActive,
  }) async {
    bool active() => isActive?.call() ?? true;

    // Decoder waits outlive a route occasionally. Never mutate a shared
    // player after its fullscreen route has already been dismissed.
    if (!active()) return false;
    final desired = target ?? player.state.position;
    if (!active()) return false;
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!active()) return false;
    await player.seek(desired);
    if (!active()) return false;
    await player.play();

    try {
      await videoController.waitUntilFirstFrameRendered.timeout(timeout);
      return true;
    } catch (_) {
      // Some native surfaces miss the first resize event when a file is
      // resumed. Re-select the automatic video stream only in this fallback;
      // doing it for every resume needlessly restarts the decoder and causes
      // visible stutter on otherwise healthy local and remote playback.
      if (!active()) return false;
      await player.pause();
      if (!active()) return false;
      if (desired > Duration.zero) {
        try {
          await player.setVideoTrack(VideoTrack.auto());
        } catch (_) {
          // Audio-only files and platforms without video-track selection can
          // continue with the decoder's existing stream.
        }
        if (!active()) return false;
      }
      await player.seek(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!active()) return false;
      await player.seek(desired);
      if (!active()) return false;
      await player.play();
      try {
        await videoController.waitUntilFirstFrameRendered.timeout(timeout);
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// Seek a resumed video and verify the native clock reached the requested
  /// position. This is shared by local files and remote/offline streams so
  /// resume semantics do not depend on the transport used to open the media.
  static Future<Duration> seekAndVerify(
    Player player,
    Duration target, {
    int attempts = 6,
    Duration tolerance = const Duration(seconds: 2),
  }) async {
    var actual = player.state.position;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      await player.seek(target);
      await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      actual = player.state.position;
      if ((actual - target).abs() <= tolerance) return actual;
    }
    throw StateError('Fortsetzungsposition konnte nicht gesetzt werden.');
  }
}
