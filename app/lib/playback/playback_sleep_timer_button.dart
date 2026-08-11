import 'package:flutter/material.dart';

import 'playback_sleep_timer.dart';

enum _SleepTimerChoice {
  off,
  minutes15,
  minutes30,
  minutes45,
  minutes60,
  customDuration,
  atTime,
  chapterEnd,
  trackEnd,
}

class PlaybackSleepTimerButton extends StatefulWidget {
  const PlaybackSleepTimerButton({
    super.key,
    required this.timer,
    this.compact = false,
    this.supportsChapterEnd = false,
  });

  final PlaybackSleepTimer timer;
  final bool compact;
  final bool supportsChapterEnd;

  @override
  State<PlaybackSleepTimerButton> createState() =>
      _PlaybackSleepTimerButtonState();
}

class _PlaybackSleepTimerButtonState extends State<PlaybackSleepTimerButton> {
  late int _shakeRestartCount;

  @override
  void initState() {
    super.initState();
    _shakeRestartCount = widget.timer.shakeRestartCount;
    widget.timer.addListener(_timerChanged);
  }

  @override
  void didUpdateWidget(covariant PlaybackSleepTimerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timer == widget.timer) return;
    oldWidget.timer.removeListener(_timerChanged);
    _shakeRestartCount = widget.timer.shakeRestartCount;
    widget.timer.addListener(_timerChanged);
  }

  void _timerChanged() {
    if (!mounted) return;
    final count = widget.timer.shakeRestartCount;
    if (count > _shakeRestartCount) {
      _shakeRestartCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sleep-Timer durch Schütteln neu gestartet.'),
            duration: Duration(seconds: 2),
          ),
        );
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.timer.removeListener(_timerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timer = widget.timer;
    final label = switch (timer.mode) {
      PlaybackSleepTimerMode.off => 'Sleep-Timer',
      PlaybackSleepTimerMode.endOfChapter => 'Am Kapitelende',
      PlaybackSleepTimerMode.endOfTrack => 'Am Trackende',
      PlaybackSleepTimerMode.atTime => 'Bis ${_clock(timer.endsAt)}',
      PlaybackSleepTimerMode.duration => _remaining(timer.remaining),
    };
    return PopupMenuButton<_SleepTimerChoice>(
      tooltip: label,
      onSelected: _select,
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: _SleepTimerChoice.off,
          checked: timer.mode == PlaybackSleepTimerMode.off,
          child: const Text('Aus'),
        ),
        for (final option in const [
          (_SleepTimerChoice.minutes15, 15),
          (_SleepTimerChoice.minutes30, 30),
          (_SleepTimerChoice.minutes45, 45),
          (_SleepTimerChoice.minutes60, 60),
        ])
          CheckedPopupMenuItem(
            value: option.$1,
            checked:
                timer.mode == PlaybackSleepTimerMode.duration &&
                timer.configuredDuration == Duration(minutes: option.$2),
            child: Text('${option.$2} Minuten'),
          ),
        const PopupMenuItem(
          value: _SleepTimerChoice.customDuration,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.tune),
            title: Text('Freie Dauer …'),
          ),
        ),
        const PopupMenuItem(
          value: _SleepTimerChoice.atTime,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.schedule),
            title: Text('Bis Uhrzeit …'),
          ),
        ),
        if (widget.supportsChapterEnd)
          CheckedPopupMenuItem(
            value: _SleepTimerChoice.chapterEnd,
            checked: timer.mode == PlaybackSleepTimerMode.endOfChapter,
            child: const Text('Am Kapitelende'),
          ),
        CheckedPopupMenuItem(
          value: _SleepTimerChoice.trackEnd,
          checked: timer.mode == PlaybackSleepTimerMode.endOfTrack,
          child: const Text('Am Trackende'),
        ),
      ],
      child: widget.compact
          ? Padding(
              padding: const EdgeInsets.all(8),
              child: Badge(
                isLabelVisible: timer.active,
                child: Icon(
                  timer.active ? Icons.bedtime : Icons.bedtime_outlined,
                ),
              ),
            )
          : Chip(
              avatar: Icon(
                timer.active ? Icons.bedtime : Icons.bedtime_outlined,
                size: 18,
              ),
              label: Text(label),
            ),
    );
  }

  Future<void> _select(_SleepTimerChoice choice) async {
    final timer = widget.timer;
    switch (choice) {
      case _SleepTimerChoice.off:
        timer.cancel();
      case _SleepTimerChoice.minutes15:
        timer.schedule(const Duration(minutes: 15));
      case _SleepTimerChoice.minutes30:
        timer.schedule(const Duration(minutes: 30));
      case _SleepTimerChoice.minutes45:
        timer.schedule(const Duration(minutes: 45));
      case _SleepTimerChoice.minutes60:
        timer.schedule(const Duration(minutes: 60));
      case _SleepTimerChoice.customDuration:
        final duration = await _askDuration();
        if (duration != null) timer.schedule(duration);
      case _SleepTimerChoice.atTime:
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.now(),
          helpText: 'Sleep-Timer bis Uhrzeit',
        );
        if (time != null && mounted) timer.scheduleAt(_nextOccurrence(time));
      case _SleepTimerChoice.chapterEnd:
        timer.scheduleEndOfChapter();
      case _SleepTimerChoice.trackEnd:
        timer.scheduleEndOfTrack();
    }
  }

  Future<Duration?> _askDuration() async {
    final controller = TextEditingController(text: '30');
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Freie Sleep-Timer-Dauer'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Minuten',
            helperText: '1 bis 1.440 Minuten',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null && value >= 1 && value <= 1440) {
                Navigator.pop(context, value);
              }
            },
            child: const Text('Starten'),
          ),
        ],
      ),
    );
    controller.dispose();
    return minutes == null ? null : Duration(minutes: minutes);
  }

  static DateTime _nextOccurrence(TimeOfDay time) {
    final now = DateTime.now();
    var target = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (!target.isAfter(now)) target = target.add(const Duration(days: 1));
    return target;
  }

  static String _clock(DateTime? value) => value == null
      ? '--:--'
      : '${value.hour.toString().padLeft(2, '0')}:'
            '${value.minute.toString().padLeft(2, '0')}';

  static String _remaining(Duration? value) {
    if (value == null) return 'Sleep-Timer';
    final totalMinutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    if (totalMinutes < 60) return '$totalMinutes:$seconds';
    final hours = value.inHours;
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }
}
