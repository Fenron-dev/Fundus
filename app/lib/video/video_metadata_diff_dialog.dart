import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

/// Fields that can be changed by an external video metadata provider.
///
/// The provider result is deliberately not applied as one opaque blob. A
/// user may want a new poster and genres while keeping a hand-written
/// description or a manual media classification.
enum VideoMetadataField {
  title,
  description,
  year,
  genres,
  contentStyle,
  sensitivity,
  structure,
  runtime,
  artwork,
  credits,
  trailer,
}

final class VideoMetadataDiffSelection {
  const VideoMetadataDiffSelection(this.fields);

  final Set<VideoMetadataField> fields;

  bool contains(VideoMetadataField field) => fields.contains(field);
}

/// Shows a compact, provider-neutral diff before external metadata is saved.
///
/// Only fields whose value differs are selectable. The default is all changed
/// fields, while manually edited data can be left untouched with one click.
Future<VideoMetadataDiffSelection?> showVideoMetadataDiffDialog(
  BuildContext context, {
  required LibraryWorkSummary current,
  required VideoProviderCandidate incoming,
}) async {
  final values =
      <
        VideoMetadataField,
        ({String label, String oldValue, String newValue})
      >{};
  void add(
    VideoMetadataField field,
    String label,
    Object? oldValue,
    Object? newValue,
  ) {
    final oldText = _displayValue(oldValue);
    final newText = _displayValue(newValue);
    if (newText.isEmpty || oldText == newText) return;
    values[field] = (label: label, oldValue: oldText, newValue: newText);
  }

  add(VideoMetadataField.title, 'Titel', current.title, incoming.title);
  add(
    VideoMetadataField.description,
    'Beschreibung',
    current.description,
    incoming.description,
  );
  add(
    VideoMetadataField.year,
    'Jahr',
    current.publishedYear,
    incoming.releaseYear,
  );
  add(VideoMetadataField.genres, 'Genres', current.genres, incoming.genres);
  add(
    VideoMetadataField.contentStyle,
    'Stil',
    current.contentStyle,
    incoming.contentStyle,
  );
  add(
    VideoMetadataField.sensitivity,
    'Inhaltsschutz',
    current.contentSensitivity,
    incoming.contentSensitivity,
  );
  add(
    VideoMetadataField.structure,
    'Struktur',
    {
      if (current.providerMetadata['season'] != null)
        'Staffel': current.providerMetadata['season'],
      if (current.providerMetadata['episode_count'] != null)
        'Folgen': current.providerMetadata['episode_count'],
    },
    {
      if (incoming.season != null) 'Staffel': incoming.season,
      if (incoming.episodeCount != null) 'Folgen': incoming.episodeCount,
    },
  );
  add(
    VideoMetadataField.runtime,
    'Laufzeit',
    current.providerMetadata['runtime_minutes'],
    incoming.runtimeMinutes,
  );
  add(
    VideoMetadataField.artwork,
    'Cover/Backdrop',
    current.coverPath == null ? null : 'Vorhanden',
    incoming.posterUrl == null ? null : 'Neues Cover',
  );
  add(
    VideoMetadataField.credits,
    'Besetzung & Crew',
    current.providerMetadata['credits'],
    incoming.credits,
  );
  add(
    VideoMetadataField.trailer,
    'Trailer',
    current.providerMetadata['trailer_url'],
    incoming.trailerUrl,
  );

  if (values.isEmpty) {
    return showDialog<VideoMetadataDiffSelection>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keine neuen Angaben'),
        content: const Text(
          'Der Anbieter liefert keine Werte, die sich von den aktuellen '
          'Metadaten unterscheiden.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Schließen'),
          ),
        ],
      ),
    );
  }

  var selected = values.keys.toSet();
  return showDialog<VideoMetadataDiffSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final allSelected = selected.length == values.length;
        return AlertDialog(
          title: Text('${incoming.provider.toUpperCase()} – Änderungen prüfen'),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Nur ausgewählte Felder werden übernommen. Eigene '
                          'Notizen, Lesezeichen und Fortschritt bleiben immer erhalten.',
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(
                          () => selected = allSelected
                              ? <VideoMetadataField>{}
                              : values.keys.toSet(),
                        ),
                        child: Text(allSelected ? 'Keine' : 'Alle'),
                      ),
                    ],
                  ),
                  const Divider(),
                  for (final entry in values.entries)
                    CheckboxListTile(
                      value: selected.contains(entry.key),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          selected.add(entry.key);
                        } else {
                          selected.remove(entry.key);
                        }
                      }),
                      title: Text(entry.value.label),
                      subtitle: _DiffValues(
                        oldValue: entry.value.oldValue,
                        newValue: entry.value.newValue,
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Abbrechen'),
            ),
            FilledButton.icon(
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      VideoMetadataDiffSelection(Set.unmodifiable(selected)),
                    ),
              icon: const Icon(Icons.check),
              label: const Text('Auswahl übernehmen'),
            ),
          ],
        );
      },
    ),
  );
}

final class _DiffValues extends StatelessWidget {
  const _DiffValues({required this.oldValue, required this.newValue});

  final String oldValue;
  final String newValue;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Bisher: $oldValue', maxLines: 2, overflow: TextOverflow.ellipsis),
        Text(
          'Neu: $newValue',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: Theme.of(context).colorScheme.primary),
        ),
      ],
    ),
  );
}

String _displayValue(Object? value) {
  if (value == null) return '';
  if (value is Iterable) {
    return value.map(_displayValue).where((item) => item.isNotEmpty).join(', ');
  }
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}: ${_displayValue(entry.value)}')
        .where((item) => item.trim().isNotEmpty)
        .join(', ');
  }
  final text = value.toString().trim();
  return text;
}
