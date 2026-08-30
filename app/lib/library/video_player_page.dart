import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/fundus_video_player_controller.dart';

Future<void> showFundusVideoPlayer(
  BuildContext context, {
  required FundusVideoPlayerController controller,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (context) => _FundusVideoPlayerPage(controller: controller),
  ),
);

final class _FundusVideoPlayerPage extends StatefulWidget {
  const _FundusVideoPlayerPage({required this.controller});

  final FundusVideoPlayerController controller;

  @override
  State<_FundusVideoPlayerPage> createState() => _FundusVideoPlayerPageState();
}

final class _FundusVideoPlayerPageState extends State<_FundusVideoPlayerPage> {
  late final VideoController _videoController;

  FundusVideoPlayerController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // Keep one native video output for the lifetime of the route. Recreating
    // this controller from build() would detach the texture on every progress
    // update and can make playback flicker or stop.
    _videoController = VideoController(controller.player);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Text(controller.work?.title ?? 'Video'),
      ),
    ),
    body: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (controller.error case final error?) {
          return Center(
            child: Text(
              error,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          );
        }
        return Center(
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Video(
              controller: _videoController,
              fit: BoxFit.contain,
              controls: AdaptiveVideoControls,
            ),
          ),
        );
      },
    ),
  );
}
