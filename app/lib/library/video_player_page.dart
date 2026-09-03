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
  videoController: controller.videoController,
  fundusController: controller,
  title: controller.work?.title ?? 'Video',
  resumePlayback: true,
);

Future<void> showFundusVideoPlayerForPlayer(
  BuildContext context, {
  required Player player,
  required VideoController videoController,
  required String title,
  FundusVideoPlayerController? fundusController,
  bool resumePlayback = true,
  Future<void> Function(AudioTrack track)? onAudioTrackSelected,
  Future<void> Function(bool enabled, SubtitleTrack? track)?
  onSubtitleTrackSelected,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (context) => _FundusVideoPlayerPage(
      player: player,
      videoController: videoController,
      title: title,
      fundusController: fundusController,
      resumePlayback: resumePlayback,
      onAudioTrackSelected: onAudioTrackSelected,
      onSubtitleTrackSelected: onSubtitleTrackSelected,
    ),
  ),
);

final class _FundusVideoPlayerPage extends StatefulWidget {
  const _FundusVideoPlayerPage({
    required this.player,
    required this.videoController,
    required this.title,
    this.fundusController,
    required this.resumePlayback,
    this.onAudioTrackSelected,
    this.onSubtitleTrackSelected,
  });
  final Player player;
  final VideoController videoController;
  final String title;
  final FundusVideoPlayerController? fundusController;
  final bool resumePlayback;
  final Future<void> Function(AudioTrack track)? onAudioTrackSelected;
  final Future<void> Function(bool enabled, SubtitleTrack? track)?
  onSubtitleTrackSelected;
  @override
  State<_FundusVideoPlayerPage> createState() => _FundusVideoPlayerPageState();
}

final class _FundusVideoPlayerPageState extends State<_FundusVideoPlayerPage> {
  @override
  void initState() {
    super.initState();
    // The player may have been opened (and even started) before this route
    // existed. Re-prime the native texture after the first frame so resumed
    // videos render their picture as reliably as freshly opened videos.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.resumePlayback) return;
      try {
        // Always re-prime the native texture after the route is mounted. A
        // resumed file can have a valid audio clock while the video output
        // is still attached to the pre-route surface; simply calling play()
        // in that state produces sound with a black or stale frame. Keep the
        // already restored timestamp, pause the decoder briefly, then seek
        // back to that timestamp before starting playback.
        final restoredPosition = widget.player.state.position;
        await widget.player.pause();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (restoredPosition > Duration.zero) {
          await widget.player.seek(restoredPosition);
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
        if (mounted) await widget.player.play();
      } catch (_) {
        // Playback errors are surfaced by media_kit's error stream/controls.
      }
    });
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
          controller: widget.videoController,
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
                    await widget.fundusController?.rememberAudioTrack(track);
                    await widget.onAudioTrackSelected?.call(track);
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
                  await widget.fundusController?.rememberSubtitlePreference(
                    enabled: false,
                  );
                  await widget.onSubtitleTrackSelected?.call(false, null);
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
                    await widget.fundusController?.rememberSubtitlePreference(
                      enabled: true,
                      selected: track,
                    );
                    await widget.onSubtitleTrackSelected?.call(true, track);
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
