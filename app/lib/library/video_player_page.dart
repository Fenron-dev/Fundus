import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
  fundusController: controller,
  title: controller.work?.title ?? 'Video',
);

Future<void> showFundusVideoPlayerForPlayer(
  BuildContext context, {
  required Player player,
  required String title,
  FundusVideoPlayerController? fundusController,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (context) => _FundusVideoPlayerPage(
      player: player,
      title: title,
      fundusController: fundusController,
    ),
  ),
);

final class _FundusVideoPlayerPage extends StatefulWidget {
  const _FundusVideoPlayerPage({
    required this.player,
    required this.title,
    this.fundusController,
  });
  final Player player;
  final String title;
  final FundusVideoPlayerController? fundusController;
  @override
  State<_FundusVideoPlayerPage> createState() => _FundusVideoPlayerPageState();
}

final class _FundusVideoPlayerPageState extends State<_FundusVideoPlayerPage> {
  late final VideoController _videoController;

  @override
  void initState() {
    super.initState();
    final wasPlaying = widget.player.state.playing;
    _videoController = VideoController(widget.player);
    // Attach the video texture before resuming a player that was opened at a
    // saved position; otherwise audio may play while the picture is black.
    if (wasPlaying) {
      widget.player.pause();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.player.play();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(widget.title),
      actions: [
        IconButton(
          tooltip: 'Tonspur und Untertitel',
          onPressed: () => _showTracks(context),
          icon: const Icon(Icons.closed_caption_outlined),
        ),
        IconButton(
          tooltip: 'Screenshot speichern',
          onPressed: () => _saveScreenshot(context),
          icon: const Icon(Icons.camera_alt_outlined),
        ),
      ],
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

  Future<void> _showTracks(BuildContext context) async {
    final audio = widget.player.state.tracks.audio;
    final subtitles = widget.player.state.tracks.subtitle;
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            if (audio.isNotEmpty) ...[
              const ListTile(title: Text('Tonspur')),
              for (final track in audio)
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: Text(track.title ?? track.language ?? track.id),
                  subtitle: Text(track.language ?? ''),
                  onTap: () async {
                    await widget.player.setAudioTrack(track);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
            ],
            if (subtitles.isNotEmpty) ...[
              const ListTile(title: Text('Untertitel')),
              ListTile(
                leading: const Icon(Icons.subtitles_off_outlined),
                title: const Text('Aus'),
                onTap: () async {
                  await widget.player.setSubtitleTrack(SubtitleTrack.no());
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              for (final track in subtitles)
                ListTile(
                  leading: const Icon(Icons.subtitles_outlined),
                  title: Text(track.title ?? track.language ?? track.id),
                  subtitle: Text(track.language ?? ''),
                  onTap: () async {
                    await widget.player.setSubtitleTrack(track);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
            ],
            if (audio.isEmpty && subtitles.isEmpty)
              const ListTile(
                title: Text('Keine alternativen Spuren gefunden.'),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveScreenshot(BuildContext context) async {
    try {
      final Uint8List? bytes = await widget.player.screenshot(
        format: 'image/png',
      );
      if (bytes == null || bytes.isEmpty || !context.mounted) return;
      final path = await FilePicker.saveFile(
        dialogTitle: 'Video-Screenshot speichern',
        fileName:
            '${widget.title.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')}.png',
        type: FileType.image,
      );
      if (path == null) return;
      await File(path).writeAsBytes(bytes, flush: true);
      await widget.fundusController?.addBookmarkAtCurrent(
        label: 'Screenshot ${_format(widget.player.state.position)}',
        note: path,
      );
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Screenshot gespeichert und als Lesezeichen abgelegt.',
            ),
          ),
        );
    } on Object catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screenshot konnte nicht gespeichert werden: $error'),
          ),
        );
    }
  }

  static String _format(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.inHours)}:${two(value.inMinutes.remainder(60))}:${two(value.inSeconds.remainder(60))}';
  }
}
