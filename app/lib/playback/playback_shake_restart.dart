import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'playback_sleep_timer.dart';

final class PlaybackShakeConfiguration {
  const PlaybackShakeConfiguration({
    this.enabled = false,
    this.threshold = 15,
    this.cooldown = const Duration(seconds: 10),
    this.hapticFeedback = true,
  });

  final bool enabled;
  final double threshold;
  final Duration cooldown;
  final bool hapticFeedback;

  PlaybackShakeConfiguration copyWith({
    bool? enabled,
    double? threshold,
    Duration? cooldown,
    bool? hapticFeedback,
  }) => PlaybackShakeConfiguration(
    enabled: enabled ?? this.enabled,
    threshold: threshold ?? this.threshold,
    cooldown: cooldown ?? this.cooldown,
    hapticFeedback: hapticFeedback ?? this.hapticFeedback,
  );
}

abstract final class PlaybackShakeSettings {
  static const _storage = FlutterSecureStorage();
  static const _enabledKey = 'fundus.playback.shake.enabled.v1';
  static const _thresholdKey = 'fundus.playback.shake.threshold.v1';
  static const _cooldownKey = 'fundus.playback.shake.cooldown_seconds.v1';
  static const _hapticKey = 'fundus.playback.shake.haptic.v1';

  static final ValueNotifier<int> changes = ValueNotifier(0);

  static Future<PlaybackShakeConfiguration> load() async {
    try {
      final values = await _storage.readAll();
      return PlaybackShakeConfiguration(
        enabled: values[_enabledKey] == 'true',
        threshold: _validThreshold(values[_thresholdKey]),
        cooldown: Duration(seconds: _validCooldown(values[_cooldownKey])),
        hapticFeedback: values[_hapticKey] != 'false',
      );
    } catch (_) {
      return const PlaybackShakeConfiguration();
    }
  }

  static Future<void> save(PlaybackShakeConfiguration value) async {
    await Future.wait([
      _storage.write(key: _enabledKey, value: '${value.enabled}'),
      _storage.write(key: _thresholdKey, value: '${value.threshold}'),
      _storage.write(key: _cooldownKey, value: '${value.cooldown.inSeconds}'),
      _storage.write(key: _hapticKey, value: '${value.hapticFeedback}'),
    ]);
    changes.value++;
  }

  static double _validThreshold(String? raw) {
    final value = double.tryParse(raw ?? '');
    return value != null && value >= 8 && value <= 30 ? value : 15;
  }

  static int _validCooldown(String? raw) {
    final value = int.tryParse(raw ?? '');
    return value != null && value >= 2 && value <= 60 ? value : 10;
  }
}

final class PlaybackAcceleration {
  const PlaybackAcceleration(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  double get magnitude => sqrt(x * x + y * y + z * z);
}

final class PlaybackShakeRestartController {
  PlaybackShakeRestartController({
    required this.timer,
    Stream<PlaybackAcceleration>? events,
    Future<PlaybackShakeConfiguration> Function()? loadConfiguration,
    Future<void> Function()? confirm,
    bool? supported,
  }) : _providedEvents = events,
       _loadConfiguration = loadConfiguration ?? PlaybackShakeSettings.load,
       _confirm = confirm ?? HapticFeedback.mediumImpact,
       _supported =
           supported ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    PlaybackShakeSettings.changes.addListener(_settingsChanged);
    unawaited(_reload());
  }

  final PlaybackSleepTimer timer;
  final Stream<PlaybackAcceleration>? _providedEvents;
  final Future<PlaybackShakeConfiguration> Function() _loadConfiguration;
  final Future<void> Function() _confirm;
  final bool _supported;

  StreamSubscription<PlaybackAcceleration>? _subscription;
  PlaybackShakeConfiguration _configuration =
      const PlaybackShakeConfiguration();
  DateTime? _lastRestart;
  bool _armed = true;
  bool _disposed = false;
  int _generation = 0;
  int _restartCount = 0;

  int get restartCount => _restartCount;

  void _settingsChanged() => unawaited(_reload());

  Future<void> _reload() async {
    final generation = ++_generation;
    final configuration = await _loadConfiguration();
    if (_disposed || generation != _generation) return;
    _configuration = configuration;
    await _subscription?.cancel();
    _subscription = null;
    _armed = true;
    if (!_supported || !configuration.enabled || _disposed) return;
    final events =
        _providedEvents ??
        userAccelerometerEventStream(
          samplingPeriod: SensorInterval.gameInterval,
        ).map((event) => PlaybackAcceleration(event.x, event.y, event.z));
    _subscription = events.listen(
      _onAcceleration,
      onError: (_) {},
      cancelOnError: true,
    );
  }

  void _onAcceleration(PlaybackAcceleration event) {
    final magnitude = event.magnitude;
    final threshold = _configuration.threshold;
    if (magnitude < threshold * 0.55) {
      _armed = true;
      return;
    }
    if (!_armed || magnitude < threshold) return;
    _armed = false;
    final now = DateTime.now();
    final last = _lastRestart;
    if (last != null && now.difference(last) < _configuration.cooldown) return;
    if (!timer.restart()) return;
    _lastRestart = now;
    _restartCount++;
    if (_configuration.hapticFeedback) unawaited(_confirm());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    PlaybackShakeSettings.changes.removeListener(_settingsChanged);
    await _subscription?.cancel();
    _subscription = null;
  }
}

class PlaybackShakeSettingTile extends StatefulWidget {
  const PlaybackShakeSettingTile({super.key});

  @override
  State<PlaybackShakeSettingTile> createState() =>
      _PlaybackShakeSettingTileState();
}

class _PlaybackShakeSettingTileState extends State<PlaybackShakeSettingTile> {
  PlaybackShakeConfiguration? _value;

  @override
  void initState() {
    super.initState();
    PlaybackShakeSettings.load().then((value) {
      if (mounted) setState(() => _value = value);
    });
  }

  Future<void> _save(PlaybackShakeConfiguration value) async {
    setState(() => _value = value);
    await PlaybackShakeSettings.save(value);
  }

  @override
  Widget build(BuildContext context) {
    final value = _value ?? const PlaybackShakeConfiguration();
    return Column(
      children: [
        SwitchListTile.adaptive(
          secondary: const Icon(Icons.vibration),
          title: const Text('Sleep-Timer durch Schütteln neu starten'),
          subtitle: const Text(
            'Nur auf Android und nur bei einem laufenden Zeittimer.',
          ),
          value: value.enabled,
          onChanged: _value == null
              ? null
              : (enabled) => _save(value.copyWith(enabled: enabled)),
        ),
        if (value.enabled) ...[
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('Empfindlichkeit'),
            trailing: DropdownButton<double>(
              value: value.threshold,
              items: const [
                DropdownMenuItem(value: 11, child: Text('Hoch')),
                DropdownMenuItem(value: 15, child: Text('Normal')),
                DropdownMenuItem(value: 20, child: Text('Niedrig')),
              ],
              onChanged: (threshold) {
                if (threshold != null) {
                  _save(value.copyWith(threshold: threshold));
                }
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.hourglass_bottom_outlined),
            title: const Text('Cooldown'),
            subtitle: const Text('Verhindert mehrfaches Auslösen.'),
            trailing: DropdownButton<int>(
              value: value.cooldown.inSeconds,
              items: const [
                DropdownMenuItem(value: 5, child: Text('5 s')),
                DropdownMenuItem(value: 10, child: Text('10 s')),
                DropdownMenuItem(value: 20, child: Text('20 s')),
              ],
              onChanged: (seconds) {
                if (seconds != null) {
                  _save(value.copyWith(cooldown: Duration(seconds: seconds)));
                }
              },
            ),
          ),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.touch_app_outlined),
            title: const Text('Haptisch bestätigen'),
            value: value.hapticFeedback,
            onChanged: (enabled) =>
                _save(value.copyWith(hapticFeedback: enabled)),
          ),
        ],
      ],
    );
  }
}
