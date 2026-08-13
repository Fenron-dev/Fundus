import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playback_shake_restart.dart';
import 'package:fundus/settings/fundus_settings_snapshot.dart';

void main() {
  test('settings snapshot round-trips without secrets', () {
    const snapshot = FundusSettingsSnapshot(
      themeMode: ThemeMode.system,
      askOnProgressConflict: false,
      shakeConfiguration: PlaybackShakeConfiguration(
        enabled: true,
        threshold: 11,
        cooldown: Duration(seconds: 20),
        hapticFeedback: false,
      ),
      deviceName: 'Wohnzimmer-Mac',
      lanEnabled: true,
    );

    final encoded = snapshot.encode();
    final restored = FundusSettingsSnapshot.decode(encoded);
    expect(restored.themeMode, ThemeMode.system);
    expect(restored.askOnProgressConflict, isFalse);
    expect(restored.shakeConfiguration.enabled, isTrue);
    expect(restored.shakeConfiguration.threshold, 11);
    expect(restored.shakeConfiguration.cooldown, const Duration(seconds: 20));
    expect(restored.deviceName, 'Wohnzimmer-Mac');
    expect(restored.lanEnabled, isTrue);
    expect(encoded, isNot(contains('"token":')));
    expect(encoded, isNot(contains('"private_key":')));
    expect(encoded, isNot(contains('/Users/')));
  });

  test('settings import rejects invalid values and versions', () {
    expect(
      () => FundusSettingsSnapshot.decode(
        '{"format":"fundus-settings","version":2}',
      ),
      throwsFormatException,
    );
    expect(
      () => FundusSettingsSnapshot.decode(
        '{"format":"fundus-settings","version":1,'
        '"display":{"theme_mode":"dark"},'
        '"playback":{"ask_on_progress_conflict":true,'
        '"shake_restart":{"enabled":true,"threshold":99,'
        '"cooldown_seconds":10,"haptic_feedback":true}},'
        '"server":{"device_name":"Test","lan_enabled":false}}',
      ),
      throwsFormatException,
    );
  });
}
