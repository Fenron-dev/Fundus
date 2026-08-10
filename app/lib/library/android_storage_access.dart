import 'dart:io';

import 'package:flutter/services.dart';

abstract final class AndroidStorageAccess {
  static const _channel = MethodChannel('dev.fundus/android_storage_access');

  static Future<bool> isGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('isGranted') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> request() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
