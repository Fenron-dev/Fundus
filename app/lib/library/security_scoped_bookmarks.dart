import 'dart:io';

import 'package:flutter/services.dart';

abstract final class SecurityScopedBookmarks {
  static const _channel = MethodChannel('dev.fundus/security_scoped_bookmarks');

  static Future<String?> create(String path) async {
    if (!Platform.isMacOS) return null;
    return _channel.invokeMethod<String>('create', {'path': path});
  }

  static Future<String?> startAccess(String? bookmark) async {
    if (!Platform.isMacOS || bookmark == null || bookmark.isEmpty) return null;
    return _channel.invokeMethod<String>('startAccess', {'bookmark': bookmark});
  }
}
