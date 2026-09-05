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

  /// Returns whether a controller has already reached the requested resume
  /// position closely enough that a second native seek is unnecessary.
  ///
  /// Kept as a pure helper so the threshold remains explicit and testable;
  /// repeated seeks are particularly expensive for HTTP range streams.
  static bool isResumePositionAligned(
    Duration current,
    Duration desired, {
    Duration tolerance = const Duration(seconds: 2),
  }) => desired <= Duration.zero || (current - desired).abs() <= tolerance;

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

  /// Waits until the [Video] route has a native texture and a non-empty
  /// surface rectangle. The first-frame future is intentionally not used for
  /// this: media-kit keeps that future for the lifetime of the native player,
  /// while a fullscreen route can be mounted many times over that lifetime.
  static Future<bool> waitForVideoOutput(
    VideoController videoController, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final id = videoController.id.value;
      final rect = videoController.rect.value;
      if (id != null && rect != null && rect.width > 1 && rect.height > 1) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    return false;
  }

  /// Prime the native video surface after the player route has been mounted.
  ///
  /// A player can have a valid clock (and therefore resume audio at the right
  /// timestamp) before the platform texture has received a frame.  The normal
  /// path only pauses and resumes after the surface is attached because the
  /// controller already performed a verified seek before mounting this route.
  /// A seek is retained as a bounded fallback for a genuinely missing frame,
  /// so a slow network stream cannot cause an endless seek loop.
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

    // The route may be a second (or later) fullscreen route for the same
    // Player. Wait for its texture rather than trusting the one-shot
    // first-frame future, which belongs to the native player and is already
    // completed after the first route.
    await waitForVideoOutput(videoController);
    if (!active()) return false;

    var firstFrameWasRendered = false;
    try {
      await videoController.waitUntilFirstFrameRendered.timeout(
        const Duration(milliseconds: 50),
      );
      firstFrameWasRendered = true;
    } catch (_) {
      // The first frame is still pending; continue with the attach/prime path.
    }
    final current = player.state.position;
    final positionAligned = isResumePositionAligned(current, desired);

    if (positionAligned) {
      // The controller has already performed the verified resume seek before
      // this route is mounted. Seeking a second time here is expensive for a
      // range-backed stream and was the source of visible stalls whenever a
      // user reopened an already visited episode. A pause/play cycle is enough
      // to attach the current decoded frame to a newly mounted texture.
      if (!active()) return false;
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (!active()) return false;
      await player.play();
      if (firstFrameWasRendered) return true;
      try {
        await videoController.waitUntilFirstFrameRendered.timeout(timeout);
        return true;
      } catch (_) {
        // Fall through to the one-time seek fallback below. This is reserved
        // for a genuinely missing frame and is no longer part of the normal
        // resume path.
      }
    }

    // A new title does not need a synthetic seek to zero. Starting it
    // directly lets the native decoder render its first frame without an
    // avoidable pause/resume hitch.
    if (desired <= Duration.zero) {
      await player.play();
      try {
        await videoController.waitUntilFirstFrameRendered.timeout(timeout);
        return true;
      } catch (_) {
        return false;
      }
    }
    await player.pause();
    await Future<void>.delayed(const Duration(milliseconds: 80));
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
    int attempts = 2,
    Duration tolerance = const Duration(seconds: 2),
  }) async {
    var actual = player.state.position;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      await player.seek(target);
      // Range-backed streams need time to complete the new request. Repeating
      // seek commands every 100 ms can cancel that request and leaves the
      // decoder with audio advancing while video is still buffering.
      await Future<void>.delayed(Duration(milliseconds: 350 * attempt));
      actual = player.state.position;
      if ((actual - target).abs() <= tolerance) return actual;
    }
    throw StateError('Fortsetzungsposition konnte nicht gesetzt werden.');
  }
}
