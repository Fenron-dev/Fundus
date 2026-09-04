import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../playback/fundus_playback_controller.dart';
import '../playback/fundus_video_playback_controller.dart';
import '../playback/fundus_video_playback_session.dart';
import '../playback/fundus_video_player_controller.dart';

Future<void> showFundusVideoPlayer(
  BuildContext context, {
  required FundusVideoPlaybackController controller,
}) => showFundusVideoPlayerForPlayer(
  context,
  controller: controller,
  fundusController: controller is FundusVideoPlayerController
      ? controller
      : null,
  title: controller.playbackWorkTitle ?? 'Video',
  resumePlayback: true,
  initialPosition: controller.position,
);

Future<void> showFundusVideoPlayerForPlayer(
  BuildContext context, {
  required FundusVideoPlaybackController controller,
  required String title,
  FundusVideoPlayerController? fundusController,
  Set<FundusPlaybackCapability>? capabilities,
  bool resumePlayback = true,
  Duration? initialPosition,
  Future<void> Function(AudioTrack track)? onAudioTrackSelected,
  Future<void> Function(bool enabled, SubtitleTrack? track)?
  onSubtitleTrackSelected,
  Future<void> Function({String? label, String? note})? onBookmarkAtCurrent,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (context) => _FundusVideoPlayerPage(
      player: controller.player,
      videoController: controller.videoController,
      title: title,
      fundusController: fundusController,
      capabilities: capabilities ?? controller.capabilities,
      resumePlayback: resumePlayback,
      initialPosition: initialPosition,
      onAudioTrackSelected: onAudioTrackSelected,
      onSubtitleTrackSelected: onSubtitleTrackSelected,
      onBookmarkAtCurrent: onBookmarkAtCurrent,
    ),
  ),
);

final class _FundusVideoPlayerPage extends StatefulWidget {
  const _FundusVideoPlayerPage({
    required this.player,
    required this.videoController,
    required this.title,
    this.fundusController,
    required this.capabilities,
    required this.resumePlayback,
    this.initialPosition,
    this.onAudioTrackSelected,
    this.onSubtitleTrackSelected,
    this.onBookmarkAtCurrent,
  });
  final Player player;
  final VideoController videoController;
  final String title;
  final FundusVideoPlayerController? fundusController;
  final Set<FundusPlaybackCapability> capabilities;
  final bool resumePlayback;
  final Duration? initialPosition;
  final Future<void> Function(AudioTrack track)? onAudioTrackSelected;
  final Future<void> Function(bool enabled, SubtitleTrack? track)?
  onSubtitleTrackSelected;
  final Future<void> Function({String? label, String? note})?
  onBookmarkAtCurrent;
  @override
  State<_FundusVideoPlayerPage> createState() => _FundusVideoPlayerPageState();
}

final class _FundusVideoPlayerPageState extends State<_FundusVideoPlayerPage> {
  var _fitMode = _VideoFitMode.contain;

  @override
  void initState() {
    super.initState();
    // The controller is opened before this route exists so local, remote and
    // offline playback can share the same setup.  The native surface is only
    // attached after the first frame of this route.  Explicitly prime it here
    // instead of relying on the decoder's previous texture: otherwise a
    // resumed file can have a valid audio clock while the video stays black.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !widget.resumePlayback) return;
      try {
        final target = widget.initialPosition ?? widget.player.state.position;
        await FundusVideoPlaybackSession.waitForVideoParameters(
          widget.player,
          timeout: const Duration(seconds: 2),
        );
        if (!mounted) return;
        final actual = widget.player.state.position;
        if (target > Duration.zero &&
            (actual - target).abs() > const Duration(seconds: 1)) {
          await widget.player.pause();
          await Future<void>.delayed(const Duration(milliseconds: 80));
          await widget.player.seek(target);
        }
        if (!widget.player.state.playing) await widget.player.play();
        try {
          await widget.videoController.waitUntilFirstFrameRendered.timeout(
            const Duration(seconds: 3),
          );
        } catch (_) {
          // Retry once when the surface was attached after the decoder. This
          // is the important recovery path for resumed MKV/MP4 playback.
          if (!mounted) return;
          await widget.player.pause();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await widget.player.seek(target > Duration.zero ? target : actual);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (mounted) await widget.player.play();
        }
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
        PopupMenuButton<_VideoFitMode>(
          tooltip: 'Darstellung',
          initialValue: _fitMode,
          onSelected: (value) => setState(() => _fitMode = value),
          itemBuilder: (context) => [
            for (final mode in _VideoFitMode.values)
              CheckedPopupMenuItem(
                value: mode,
                checked: mode == _fitMode,
                child: Text(mode.label),
              ),
          ],
          icon: const Icon(Icons.fit_screen_outlined),
        ),
        if (widget.capabilities.supports(
          FundusPlaybackCapability.trackSelection,
        ))
          IconButton(
            tooltip: 'Tonspur und Untertitel',
            onPressed: () => _showTracks(context),
            icon: const Icon(Icons.closed_caption_outlined),
          ),
        if (widget.capabilities.supports(FundusPlaybackCapability.screenshots))
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
          fit: _fitMode.fit,
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
      final label = 'Screenshot ${_format(widget.player.state.position)}';
      if (widget.onBookmarkAtCurrent case final saveBookmark?) {
        await saveBookmark(label: label, note: path);
      } else {
        await widget.fundusController?.addBookmarkAtCurrent(
          label: label,
          note: path,
        );
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Screenshot gespeichert und als Lesezeichen abgelegt.',
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Screenshot konnte nicht gespeichert werden: $error'),
          ),
        );
      }
    }
  }

  static String _format(Duration value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(value.inHours)}:${two(value.inMinutes.remainder(60))}:${two(value.inSeconds.remainder(60))}';
  }
}

enum _VideoFitMode {
  contain('Einpassen', BoxFit.contain),
  cover('Ausfüllen', BoxFit.cover),
  fill('Strecken', BoxFit.fill);

  const _VideoFitMode(this.label, this.fit);

  final String label;
  final BoxFit fit;
}
