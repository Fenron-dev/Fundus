import 'dart:convert';

import 'package:flutter/material.dart';

import '../playback/playback_conflict_settings.dart';
import '../playback/playback_shake_restart.dart';

enum FundusSettingScope { device, library, server, userProfile }

final class FundusSettingsSnapshot {
  const FundusSettingsSnapshot({
    required this.themeMode,
    required this.askOnProgressConflict,
    required this.shakeConfiguration,
    required this.deviceName,
    required this.lanEnabled,
  });

  static const schemaVersion = 1;
  static const maximumImportBytes = 128 * 1024;

  final ThemeMode themeMode;
  final bool askOnProgressConflict;
  final PlaybackShakeConfiguration shakeConfiguration;
  final String deviceName;
  final bool lanEnabled;

  static Future<FundusSettingsSnapshot> capture({
    required ThemeMode themeMode,
    required String deviceName,
    required bool lanEnabled,
  }) async => FundusSettingsSnapshot(
    themeMode: themeMode,
    askOnProgressConflict: await PlaybackConflictSettings.askBeforeJumping(),
    shakeConfiguration: await PlaybackShakeSettings.load(),
    deviceName: deviceName,
    lanEnabled: lanEnabled,
  );

  Map<String, Object?> toJson() => {
    'format': 'fundus-settings',
    'version': schemaVersion,
    'exported_at': DateTime.now().toUtc().toIso8601String(),
    'display': {'theme_mode': themeMode.name},
    'playback': {
      'ask_on_progress_conflict': askOnProgressConflict,
      'shake_restart': {
        'enabled': shakeConfiguration.enabled,
        'threshold': shakeConfiguration.threshold,
        'cooldown_seconds': shakeConfiguration.cooldown.inSeconds,
        'haptic_feedback': shakeConfiguration.hapticFeedback,
      },
    },
    'server': {'device_name': deviceName, 'lan_enabled': lanEnabled},
    'excluded_for_security': [
      'pairing_tokens',
      'private_keys',
      'certificate_material',
      'library_paths',
    ],
  };

  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  static FundusSettingsSnapshot decode(String source) {
    if (utf8.encode(source).length > maximumImportBytes) {
      throw const FormatException('Die Einstellungsdatei ist zu groß.');
    }
    final value = jsonDecode(source);
    if (value is! Map ||
        value['format'] != 'fundus-settings' ||
        value['version'] != schemaVersion) {
      throw const FormatException(
        'Unbekanntes oder nicht unterstütztes Einstellungsformat.',
      );
    }
    final display = value['display'];
    final playback = value['playback'];
    final server = value['server'];
    if (display is! Map || playback is! Map || server is! Map) {
      throw const FormatException('Erforderliche Einstellungsbereiche fehlen.');
    }
    final shake = playback['shake_restart'];
    if (shake is! Map) {
      throw const FormatException('Die Schüttel-Einstellungen fehlen.');
    }
    final theme = _enumByName(ThemeMode.values, display['theme_mode']);
    final ask = playback['ask_on_progress_conflict'];
    final enabled = shake['enabled'];
    final threshold = shake['threshold'];
    final cooldown = shake['cooldown_seconds'];
    final haptic = shake['haptic_feedback'];
    final deviceName = server['device_name'];
    final lanEnabled = server['lan_enabled'];
    if (theme == null ||
        ask is! bool ||
        enabled is! bool ||
        threshold is! num ||
        threshold < 8 ||
        threshold > 30 ||
        cooldown is! int ||
        cooldown < 2 ||
        cooldown > 60 ||
        haptic is! bool ||
        deviceName is! String ||
        deviceName.trim().isEmpty ||
        deviceName.trim().length > 80 ||
        lanEnabled is! bool) {
      throw const FormatException(
        'Mindestens ein Einstellungswert ist ungültig.',
      );
    }
    return FundusSettingsSnapshot(
      themeMode: theme,
      askOnProgressConflict: ask,
      shakeConfiguration: PlaybackShakeConfiguration(
        enabled: enabled,
        threshold: threshold.toDouble(),
        cooldown: Duration(seconds: cooldown),
        hapticFeedback: haptic,
      ),
      deviceName: deviceName.trim(),
      lanEnabled: lanEnabled,
    );
  }

  List<String> preview() => [
    'Darstellung: ${switch (themeMode) {
      ThemeMode.system => 'System',
      ThemeMode.light => 'Hell',
      ThemeMode.dark => 'Dunkel',
    }}',
    'Fortschrittskonflikte: ${askOnProgressConflict ? 'nachfragen' : 'neueren Stand übernehmen'}',
    'Schütteln: ${shakeConfiguration.enabled ? 'aktiv' : 'aus'}',
    'Schüttel-Empfindlichkeit: ${shakeConfiguration.threshold.toStringAsFixed(0)}',
    'Schüttel-Cooldown: ${shakeConfiguration.cooldown.inSeconds} s',
    'Gerätename: $deviceName',
    'LAN-Freigabe: ${lanEnabled ? 'aktiv' : 'aus'}',
  ];

  static T? _enumByName<T extends Enum>(Iterable<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}
