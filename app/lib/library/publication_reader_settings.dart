import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus_core/fundus_core.dart';

abstract final class PublicationReaderSettings {
  static const _storage = FlutterSecureStorage();
  static const _comicProfileKey = 'fundus.reader.comic.profile.v1';

  static Future<PublicationReaderProfile> loadComicProfile() async {
    try {
      final source = await _storage.read(key: _comicProfileKey);
      if (source == null) return const PublicationReaderProfile();
      final value = jsonDecode(source);
      if (value is! Map) return const PublicationReaderProfile();
      return PublicationReaderProfile.fromJson(value.cast<String, Object?>());
    } catch (_) {
      return const PublicationReaderProfile();
    }
  }

  static Future<void> saveComicProfile(PublicationReaderProfile profile) async {
    try {
      await _storage.write(
        key: _comicProfileKey,
        value: jsonEncode(profile.toJson()),
      );
    } catch (_) {
      // Reader settings are optional and must never prevent opening a work.
    }
  }
}
