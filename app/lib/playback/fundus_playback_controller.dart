import 'package:flutter/foundation.dart';

/// Media-neutral playback contract shared by local, remote and offline
/// controllers.
///
/// The concrete controllers still own their transport-specific details (for
/// example media-kit video tracks or a remote range proxy), but UI and sync
/// code can depend on this contract instead of branching on the origin.  The
/// contract is deliberately small so the existing controllers can adopt it
/// incrementally without introducing a second playback implementation.
abstract interface class FundusPlaybackController {
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
