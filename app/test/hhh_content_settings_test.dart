import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/settings/hhh_content_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('fundus-hhh-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationSupportDirectory') {
            return support.path;
          }
          return null;
        });
    HhhContentSettings.lock();
  });

  tearDown(() async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await support.delete(recursive: true);
  });

  test('legacy enabled setting maps to visible and hidden modes', () async {
    await HhhContentSettings.setEnabled(true);
    expect(await HhhContentSettings.mode(), HhhVisibilityMode.visible);
    expect(await HhhContentSettings.enabled(), isTrue);

    await HhhContentSettings.setEnabled(false);
    expect(await HhhContentSettings.mode(), HhhVisibilityMode.hidden);
    expect(await HhhContentSettings.enabled(), isFalse);
  });

  test('protected mode stays hidden until a valid session unlock', () async {
    await HhhContentSettings.setPin('2468');
    await HhhContentSettings.setMode(HhhVisibilityMode.protected);
    expect(await HhhContentSettings.hasPin(), isTrue);
    expect(await HhhContentSettings.isVisible(), isFalse);
    expect(await HhhContentSettings.unlock('0000'), isFalse);
    expect(await HhhContentSettings.isVisible(), isFalse);
    expect(await HhhContentSettings.unlock('2468'), isTrue);
    expect(await HhhContentSettings.isVisible(), isTrue);
    HhhContentSettings.lock();
    expect(await HhhContentSettings.isVisible(), isFalse);
  });

  test('short pins are rejected', () async {
    expect(HhhContentSettings.setPin('123'), throwsArgumentError);
  });
}
