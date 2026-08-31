import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fundus_core/fundus_core.dart';

import 'video_metadata_provider.dart';

const _tmdbKeyStorageKey = 'fundus.video.tmdb_api_key';
const _secureStorage = FlutterSecureStorage();

/// Searches provider-neutral video metadata and returns the candidate selected
/// by the user. AniList works without credentials; a TMDB key is kept only in
/// the platform's secure storage and is never written into a Fundus vault.
Future<VideoProviderCandidate?> showVideoMetadataDialog(
  BuildContext context, {
  required String initialQuery,
  required bool anime,
}) => showDialog<VideoProviderCandidate>(
  context: context,
  builder: (context) => _VideoMetadataDialog(
    initialQuery: initialQuery,
    initialProvider: anime
        ? _VideoProviderChoice.anilist
        : _VideoProviderChoice.tmdb,
  ),
);

enum _VideoProviderChoice { anilist, tmdb }

final class _VideoMetadataDialog extends StatefulWidget {
  const _VideoMetadataDialog({
    required this.initialQuery,
    required this.initialProvider,
  });

  final String initialQuery;
  final _VideoProviderChoice initialProvider;

  @override
  State<_VideoMetadataDialog> createState() => _VideoMetadataDialogState();
}

final class _VideoMetadataDialogState extends State<_VideoMetadataDialog> {
  late final TextEditingController _query;
  final _apiKey = TextEditingController();
  late _VideoProviderChoice _provider;
  bool _loading = false;
  String? _error;
  List<VideoProviderMatch> _matches = const [];

  @override
  void initState() {
    super.initState();
    _query = TextEditingController(text: widget.initialQuery);
    _provider = widget.initialProvider;
    _loadKey();
  }

  Future<void> _loadKey() async {
    _apiKey.text = await _secureStorage.read(key: _tmdbKeyStorageKey) ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final key = _apiKey.text.trim();
    if (_provider == _VideoProviderChoice.tmdb && key.isEmpty) {
      setState(
        () => _error = 'Für TMDB wird ein eigener API-Schlüssel benötigt.',
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    if (_provider == _VideoProviderChoice.tmdb) {
      await _secureStorage.write(key: _tmdbKeyStorageKey, value: key);
    }
    final provider = _provider == _VideoProviderChoice.anilist
        ? AniListVideoProvider()
        : TmdbVideoProvider(apiKey: key);
    try {
      final results = await VideoMetadataService([
        provider,
      ]).search(query, language: 'de-DE');
      if (!mounted) return;
      setState(() {
        _matches = results;
        _loading = false;
        if (results.isEmpty) _error = 'Keine passenden Treffer gefunden.';
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Metadatensuche fehlgeschlagen: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Film- und Seriendetails laden'),
    content: SizedBox(
      width: 680,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<_VideoProviderChoice>(
            segments: const [
              ButtonSegment(
                value: _VideoProviderChoice.anilist,
                label: Text('AniList'),
              ),
              ButtonSegment(
                value: _VideoProviderChoice.tmdb,
                label: Text('TMDB'),
              ),
            ],
            selected: {_provider},
            onSelectionChanged: _loading
                ? null
                : (value) => setState(() => _provider = value.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(
              labelText: 'Titel',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          if (_provider == _VideoProviderChoice.tmdb) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _apiKey,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'TMDB API-Schlüssel',
                helperText:
                    'Wird ausschließlich sicher auf diesem Gerät gespeichert.',
              ),
            ),
          ],
          const SizedBox(height: 12),
          if (_loading) const LinearProgressIndicator(),
          if (_error case final error?) ...[
            const SizedBox(height: 8),
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          if (_matches.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _matches.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final match = _matches[index];
                  final item = match.candidate;
                  return ListTile(
                    leading: item.posterUrl == null
                        ? const Icon(Icons.movie_outlined)
                        : Image.network(
                            item.posterUrl!,
                            width: 44,
                            height: 62,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                    title: Text(item.title),
                    subtitle: Text(
                      [
                        item.releaseYear?.toString(),
                        item.videoKind == 'movie' ? 'Film' : 'Serie',
                        item.provider.toUpperCase(),
                      ].whereType<String>().join(' · '),
                    ),
                    trailing: Text('${(match.score * 100).round()} %'),
                    onTap: () => Navigator.of(context).pop(item),
                  );
                },
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Abbrechen'),
      ),
      FilledButton.icon(
        onPressed: _loading ? null : _search,
        icon: const Icon(Icons.search),
        label: const Text('Suchen'),
      ),
    ],
  );

  @override
  void dispose() {
    _query.dispose();
    _apiKey.dispose();
    super.dispose();
  }
}
