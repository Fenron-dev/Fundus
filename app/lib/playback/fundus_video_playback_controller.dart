import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'fundus_playback_controller.dart';

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
