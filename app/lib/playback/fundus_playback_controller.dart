import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Actions a playback controller can perform.
///
/// The set is intentionally media-neutral.  A UI can use it to decide which
/// controls to render without branching on local/remote/offline origin or on
/// a concrete controller implementation.
enum FundusPlaybackCapability {
  playPause,
  seek,
  previous,
  next,
  speed,
  trackSelection,
  subtitles,
  chapters,
  queue,
  sleepTimer,
  systemMediaControls,
  screenshots,
  bookmarks,
}

extension FundusPlaybackCapabilitySet on Set<FundusPlaybackCapability> {
  bool supports(FundusPlaybackCapability capability) => contains(capability);
}

/// Media-neutral playback contract shared by local, remote and offline
/// controllers.
///
/// The concrete controllers still own their transport-specific details (for
/// example media-kit video tracks or a remote range proxy), but UI and sync
/// code can depend on this contract instead of branching on the origin.  The
/// contract is deliberately small so the existing controllers can adopt it
/// incrementally without introducing a second playback implementation.
abstract interface class FundusPlaybackController {
  /// Capabilities exposed by this controller instance.
  ///
  /// The returned set must be immutable (or otherwise safe to retain) so
  /// generic widgets can cache it while a player route is open.
  Set<FundusPlaybackCapability> get capabilities;

  /// The notifier surface is part of the contract so generic player widgets
  /// can subscribe without knowing the concrete controller type.
  void addListener(VoidCallback listener);

  void removeListener(VoidCallback listener);

  String? get playbackWorkId;

  String? get playbackWorkTitle;

  String? get playbackKind;

  String? get playbackTrackId;

  String? get playbackTrackTitle;

  int get currentIndex;

  int get trackCount;

  Duration get position;

  Duration get duration;

  bool get playing;

  bool get loading;

  String? get error;

  Future<void> playOrPause();

  Future<void> persist({bool finished = false});

  Future<void> seek(Duration position);

  Future<void> next();

  Future<void> previous();

  Future<void> close();
}

/// Video-specific handle exposed by every video origin.
///
/// The generic playback contract remains media-neutral; this small extension
/// lets the shared video route consume local, remote and offline controllers
/// without reaching into transport-specific implementations.
abstract interface class FundusVideoPlaybackController
    implements FundusPlaybackController {
  Player get player;

  VideoController get videoController;
}
