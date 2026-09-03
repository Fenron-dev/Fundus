import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// User configurable progress write intervals per media family.
///
/// A value of zero means that no periodic write is performed; explicit writes
/// on pause, chapter/file changes and closing still persist the position.
abstract final class PlaybackAutosaveSettings {
  static const _storage = FlutterSecureStorage();
  static final changes = ValueNotifier<int>(0);
  static const defaults = <String, int>{
    'audiobook': 30,
    'video': 30,
    'movie': 30,
    'tv': 30,
    'manga': 0,
    'webnovel': 120,
    'ebook': 120,
    'document': 120,
  };
  static const _keys = <String, String>{
    'audiobook': 'fundus.playback.autosave.audiobook.v1',
    'video': 'fundus.playback.autosave.video.v1',
    'movie': 'fundus.playback.autosave.video.v1',
    'tv': 'fundus.playback.autosave.video.v1',
    'manga': 'fundus.playback.autosave.manga.v1',
    'webnovel': 'fundus.playback.autosave.webnovel.v1',
    'ebook': 'fundus.playback.autosave.ebook.v1',
    'document': 'fundus.playback.autosave.document.v1',
  };

  static final Map<String, int> _cache = {...defaults};
  static Future<Map<String, int>>? _loadOperation;

  static Future<Map<String, int>> load() {
    return _loadOperation ??= _read().whenComplete(() => _loadOperation = null);
  }

  static Future<Map<String, int>> _read() async {
    try {
      final values = await _storage.readAll();
      for (final entry in _keys.entries) {
        final parsed = int.tryParse(values[entry.value] ?? '');
        if (parsed != null && _valid(parsed)) _cache[entry.key] = parsed;
      }
    } catch (_) {
      // Secure storage can be unavailable during early app startup. Defaults
      // remain safe and a later settings screen can retry the read.
    }
    return Map.unmodifiable(_cache);
  }

  static int intervalSeconds(String kind) =>
      _cache[kind] ?? _cache[_baseKind(kind)] ?? 60;

  static Duration interval(String kind) =>
      Duration(seconds: intervalSeconds(kind));

  static Future<void> setInterval(String kind, int seconds) async {
    final key = _keys[kind] ?? _keys[_baseKind(kind)];
    if (key == null || !_valid(seconds)) return;
    final base = _baseKind(kind);
    _cache[base] = seconds;
    await _storage.write(key: key, value: '$seconds');
    changes.value++;
  }

  static String _baseKind(String kind) {
    final normalized = kind.trim().toLowerCase();
    return switch (normalized) {
      'movie' ||
      'tv' ||
      'anime_movie' ||
      'anime_tv' ||
      'hhh_movie' ||
      'hhh_tv' => 'video',
      _ => normalized,
    };
  }

  static bool _valid(int seconds) =>
      seconds == 0 || (seconds >= 15 && seconds <= 600);
}

class PlaybackAutosaveSettingTile extends StatefulWidget {
  const PlaybackAutosaveSettingTile({super.key});

  @override
  State<PlaybackAutosaveSettingTile> createState() =>
      _PlaybackAutosaveSettingTileState();
}

class _PlaybackAutosaveSettingTileState
    extends State<PlaybackAutosaveSettingTile> {
  late Future<Map<String, int>> _values;

  @override
  void initState() {
    super.initState();
    _values = PlaybackAutosaveSettings.load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, int>>(
    future: _values,
    builder: (context, snapshot) {
      final values = snapshot.data ?? PlaybackAutosaveSettings.defaults;
      return Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.save_outlined),
                title: Text('Fortschritt automatisch speichern'),
                subtitle: Text(
                  'Die Abstände gelten je Medientyp. Beim Pausieren, Wechseln '
                  'und Schließen wird immer sofort gespeichert.',
                ),
              ),
              for (final entry in const [
                ('audiobook', 'Hörbücher'),
                ('video', 'Filme und Serien'),
                ('manga', 'Manga und Comics'),
                ('webnovel', 'Webnovels'),
                ('ebook', 'E-Books und PDFs'),
              ])
                _intervalRow(context, values, entry.$1, entry.$2),
            ],
          ),
        ),
      );
    },
  );

  Widget _intervalRow(
    BuildContext context,
    Map<String, int> values,
    String kind,
    String label,
  ) {
    final value =
        values[kind] ?? PlaybackAutosaveSettings.intervalSeconds(kind);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label),
      trailing: DropdownButton<int>(
        value: value,
        items: const [
          DropdownMenuItem(value: 0, child: Text('Nur Ereignisse')),
          DropdownMenuItem(value: 15, child: Text('15 Sekunden')),
          DropdownMenuItem(value: 30, child: Text('30 Sekunden')),
          DropdownMenuItem(value: 60, child: Text('1 Minute')),
          DropdownMenuItem(value: 120, child: Text('2 Minuten')),
          DropdownMenuItem(value: 180, child: Text('3 Minuten')),
          DropdownMenuItem(value: 300, child: Text('5 Minuten')),
        ],
        onChanged: (next) async {
          if (next == null) return;
          await PlaybackAutosaveSettings.setInterval(kind, next);
          if (!mounted) return;
          setState(() => _values = PlaybackAutosaveSettings.load());
        },
      ),
    );
  }
}
