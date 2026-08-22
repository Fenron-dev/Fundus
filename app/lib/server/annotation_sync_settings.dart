import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract final class AnnotationSyncSettings {
  static const _storage = FlutterSecureStorage();
  static const _key = 'fundus.sync.annotations.v1';

  static Future<bool> enabled() async {
    try {
      return await _storage.read(key: _key) != 'false';
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool value) async {
    try {
      await _storage.write(key: _key, value: '$value');
    } catch (_) {
      // Optional preference; synchronization stays enabled by default.
    }
  }
}

class AnnotationSyncSettingTile extends StatefulWidget {
  const AnnotationSyncSettingTile({super.key});

  @override
  State<AnnotationSyncSettingTile> createState() =>
      _AnnotationSyncSettingTileState();
}

class _AnnotationSyncSettingTileState extends State<AnnotationSyncSettingTile> {
  var _enabled = true;

  @override
  void initState() {
    super.initState();
    AnnotationSyncSettings.enabled().then((value) {
      if (mounted) setState(() => _enabled = value);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    secondary: const Icon(Icons.sync_outlined),
    title: const Text('Notizen und Favoriten synchronisieren'),
    subtitle: const Text(
      'Spiegelt Markdown-Notizen und Tags mit dem verbundenen Fundus-Server.',
    ),
    value: _enabled,
    onChanged: (value) async {
      setState(() => _enabled = value);
      await AnnotationSyncSettings.setEnabled(value);
    },
  );
}
