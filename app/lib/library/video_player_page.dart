import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/fundus_video_player_controller.dart';

Future<void> showFundusVideoPlayer(
  BuildContext context, {
  required FundusVideoPlayerController controller,
}) => showFundusVideoPlayerForPlayer(
  context,
  player: controller.player,
  title: controller.work?.title ?? 'Video',
);

/// Opens the shared video surface for a local or remote media-kit player.
///
/// Keeping the page independent of the source controller lets the remote
/// player reuse the same controls while retaining its existing sync logic.
Future<void> showFundusVideoPlayerForPlayer(
  BuildContext context, {
  required Player player,
  required String title,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (context) => _FundusVideoPlayerPage(player: player, title: title),
  ),
);

final class _FundusVideoPlayerPage extends StatefulWidget {
  const _FundusVideoPlayerPage({required this.player, required this.title});

  final Player player;
  final String title;

  @override
  State<_FundusVideoPlayerPage> createState() => _FundusVideoPlayerPageState();
}

final class _FundusVideoPlayerPageState extends State<_FundusVideoPlayerPage> {
  late final VideoController _videoController;

  @override
  void initState() {
    super.initState();
    // Keep one native video output for the lifetime of the route. Recreating
    // this controller from build() would detach the texture on every progress
    // update and can make playback flicker or stop.
    _videoController = VideoController(widget.player);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(widget.title),
    ),
    body: Center(
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Video(
          controller: _videoController,
          fit: BoxFit.contain,
          controls: AdaptiveVideoControls,
        ),
      ),
    ),
  );
}
