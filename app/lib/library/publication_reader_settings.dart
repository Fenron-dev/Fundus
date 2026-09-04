import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum ReflowFontFamily { system, serif, sansSerif, monospace }

extension ReflowFontFamilyPresentation on ReflowFontFamily {
  String get label => switch (this) {
    ReflowFontFamily.system => 'Systemschrift',
    ReflowFontFamily.serif => 'Serif',
    ReflowFontFamily.sansSerif => 'Sans Serif',
    ReflowFontFamily.monospace => 'Monospace',
  };

  String? get familyName => switch (this) {
    ReflowFontFamily.system => null,
    ReflowFontFamily.serif => 'serif',
    ReflowFontFamily.sansSerif => 'sans-serif',
    ReflowFontFamily.monospace => 'monospace',
  };
}

final class ReflowReaderProfile {
  const ReflowReaderProfile({
    this.fontFamily = ReflowFontFamily.system,
    this.fontSize = 19,
    this.lineHeight = 1.55,
    this.contentWidth = 760,
    this.paragraphSpacing = 18,
    this.sepia = false,
  });

  final ReflowFontFamily fontFamily;
  final double fontSize;
  final double lineHeight;
  final double contentWidth;
  final double paragraphSpacing;
  final bool sepia;

  ReflowReaderProfile copyWith({
    ReflowFontFamily? fontFamily,
    double? fontSize,
    double? lineHeight,
    double? contentWidth,
    double? paragraphSpacing,
    bool? sepia,
  }) => ReflowReaderProfile(
    fontFamily: fontFamily ?? this.fontFamily,
    fontSize: (fontSize ?? this.fontSize).clamp(12, 40),
    lineHeight: (lineHeight ?? this.lineHeight).clamp(1.1, 2.4),
    contentWidth: (contentWidth ?? this.contentWidth).clamp(320, 1400),
    paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing).clamp(0, 48),
    sepia: sepia ?? this.sepia,
  );

  Map<String, Object?> toJson() => {
    'schema_version': 1,
    'font_family': fontFamily.name,
    'font_size': fontSize,
    'line_height': lineHeight,
    'content_width': contentWidth,
    'paragraph_spacing': paragraphSpacing,
    'sepia': sepia,
  };

  factory ReflowReaderProfile.fromJson(Map<String, Object?> json) {
    final family = ReflowFontFamily.values
        .where((value) => value.name == json['font_family'])
        .firstOrNull;
    return const ReflowReaderProfile().copyWith(
      fontFamily: family,
      fontSize: (json['font_size'] as num?)?.toDouble(),
      lineHeight: (json['line_height'] as num?)?.toDouble(),
      contentWidth: (json['content_width'] as num?)?.toDouble(),
      paragraphSpacing: (json['paragraph_spacing'] as num?)?.toDouble(),
      sepia: json['sepia'] as bool?,
    );
  }
}

abstract final class PublicationReaderSettings {
  static const _legacyStorage = FlutterSecureStorage();
  static const _deviceKeyStorageKey = 'fundus.reader.device-key.v1';
  static const _legacyComicProfileKey = 'fundus.reader.comic.profile.v1';
  static const _defaultProfileKey = 'default';
  static Future<void> _writes = Future.value();

  /// Stable per-installation key used for portable reader profiles.
  ///
  /// Using only `Platform.operatingSystem` made every Android device share one
  /// profile on a remote library.  A secure, opaque key keeps phone, tablet
  /// and desktop preferences independent while remaining safe to put in the
  /// library sidecar (the key contains no device-identifying data).
  static Future<String> deviceKey() async {
    await _writes;
    final existing = await _legacyStorage.read(key: _deviceKeyStorageKey);
    if (existing != null && existing.trim().isNotEmpty) return existing.trim();
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    final value = 'reader-${base64UrlEncode(bytes).replaceAll('=', '')}';
    await _legacyStorage.write(key: _deviceKeyStorageKey, value: value);
    return value;
  }

  static Future<PublicationReaderProfile> loadComicProfile({
    String? workId,
  }) async {
    try {
      await _writes;
      final values = await _readValues();
      final profiles = values['profiles'];
      if (profiles is Map) {
        final value =
            profiles[workId ?? _defaultProfileKey] ??
            profiles[_defaultProfileKey];
        if (value is Map) {
          return PublicationReaderProfile.fromJson(
            Map<String, Object?>.from(value),
          );
        }
      }
      final legacy = await _legacyStorage.read(key: _legacyComicProfileKey);
      if (legacy != null) {
        final value = jsonDecode(legacy);
        if (value is Map) {
          final profile = PublicationReaderProfile.fromJson(
            Map<String, Object?>.from(value),
          );
          await saveComicProfile(profile, workId: workId);
          return profile;
        }
      }
    } catch (_) {
      // Reader preferences are optional; fall back to safe defaults.
    }
    return const PublicationReaderProfile();
  }

  static Future<void> saveComicProfile(
    PublicationReaderProfile profile, {
    String? workId,
  }) {
    final operation = _writes.then((_) async {
      try {
        final values = await _readValues();
        final profiles = values['profiles'] is Map
            ? Map<String, Object?>.from(values['profiles'] as Map)
            : <String, Object?>{};
        profiles[workId ?? _defaultProfileKey] = profile.toJson();
        values['profiles'] = profiles;
        await _writeValues(values);
      } catch (_) {
        // Reader settings are optional and must never prevent opening a work.
      }
    });
    _writes = operation;
    return operation;
  }

  static Future<ReflowReaderProfile> loadReflowProfile({String? workId}) async {
    try {
      await _writes;
      final values = await _readValues();
      final profiles = values['reflow_profiles'];
      if (profiles is Map) {
        final value =
            profiles[workId ?? _defaultProfileKey] ??
            profiles[_defaultProfileKey];
        if (value is Map) {
          return ReflowReaderProfile.fromJson(Map<String, Object?>.from(value));
        }
      }
    } catch (_) {
      // Reader preferences are optional; fall back to safe defaults.
    }
    return const ReflowReaderProfile();
  }

  static Future<bool> hasReflowProfile(String workId) async {
    try {
      await _writes;
      final profiles = (await _readValues())['reflow_profiles'];
      return profiles is Map && profiles[workId] is Map;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveReflowProfile(
    ReflowReaderProfile profile, {
    String? workId,
  }) {
    final operation = _writes.then((_) async {
      try {
        final values = await _readValues();
        final profiles = values['reflow_profiles'] is Map
            ? Map<String, Object?>.from(values['reflow_profiles'] as Map)
            : <String, Object?>{};
        profiles[workId ?? _defaultProfileKey] = profile.toJson();
        values['reflow_profiles'] = profiles;
        await _writeValues(values);
      } catch (_) {
        // Reader settings are optional and must never prevent reading.
      }
    });
    _writes = operation;
    return operation;
  }

  static Future<ReflowReaderProfile> clearReflowProfile(String workId) {
    late final Future<ReflowReaderProfile> operation;
    operation = _writes.then((_) async {
      try {
        final values = await _readValues();
        final profiles = values['reflow_profiles'] is Map
            ? Map<String, Object?>.from(values['reflow_profiles'] as Map)
            : <String, Object?>{};
        profiles.remove(workId);
        values['reflow_profiles'] = profiles;
        await _writeValues(values);
        final fallback = profiles[_defaultProfileKey];
        if (fallback is Map) {
          return ReflowReaderProfile.fromJson(
            Map<String, Object?>.from(fallback),
          );
        }
      } catch (_) {
        // Fall through to the built-in profile.
      }
      return const ReflowReaderProfile();
    });
    _writes = operation.then<void>((_) {});
    return operation;
  }

  static Future<MediaPosition?> loadDevicePosition({
    required String libraryId,
    required String workId,
  }) async {
    try {
      await _writes;
      final values = await _readValues();
      final positions = values['positions'];
      final value = positions is Map ? positions['$libraryId/$workId'] : null;
      return value is Map
          ? MediaPosition.fromJson(Map<String, Object?>.from(value))
          : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveDevicePosition({
    required String libraryId,
    required String workId,
    required MediaPosition position,
  }) {
    final operation = _writes.then((_) async {
      try {
        final values = await _readValues();
        final positions = values['positions'] is Map
            ? Map<String, Object?>.from(values['positions'] as Map)
            : <String, Object?>{};
        positions['$libraryId/$workId'] = position.toJson();
        values['positions'] = positions;
        await _writeValues(values);
      } catch (_) {
        // Device checkpoints are a convenience and must not block reading.
      }
    });
    _writes = operation;
    return operation;
  }

  static Future<Map<String, Object?>> _readValues() async {
    final file = await _settingsFile();
    if (!await file.exists()) return <String, Object?>{};
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map
        ? Map<String, Object?>.from(decoded)
        : <String, Object?>{};
  }

  static Future<void> _writeValues(Map<String, Object?> values) async {
    final file = await _settingsFile();
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.part');
    await partial.writeAsString(jsonEncode(values), flush: true);
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
  }

  static Future<File> _settingsFile() async {
    final directory = await getApplicationSupportDirectory();
    return File(p.join(directory.path, 'reader-settings.json'));
  }
}
