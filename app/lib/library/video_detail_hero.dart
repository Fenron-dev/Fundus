import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

import 'fundus_breadcrumbs.dart';
import 'media_content_schema.dart';

/// Shared Plex-inspired identity block for video works.
///
/// The hero deliberately accepts a cover builder so local, remote and offline
/// details can use the same layout without coupling the widget to a storage
/// or transport implementation.
class FundusVideoDetailHero extends StatelessWidget {
  const FundusVideoDetailHero({
    super.key,
    required this.work,
    required this.coverBuilder,
    this.directoryPath,
    this.onOpen,
    this.onLoadMetadata,
    this.onChangeType,
    this.onSelectPerson,
    this.onSelectTag,
    this.onSelectCollection,
    this.collectionNames = const [],
    this.favorite = false,
    this.onToggleFavorite,
    this.onCoverTap,
    this.breadcrumbs = const [],
  });

  final LibraryWorkSummary work;
  final WidgetBuilder coverBuilder;
  final String? directoryPath;
  final VoidCallback? onOpen;
  final VoidCallback? onLoadMetadata;
  final VoidCallback? onChangeType;
  final ValueChanged<String>? onSelectPerson;
  final ValueChanged<String>? onSelectTag;
  final ValueChanged<String>? onSelectCollection;
  final List<String> collectionNames;
  final bool favorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onCoverTap;
  final List<FundusBreadcrumb> breadcrumbs;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scheme = Theme.of(context).colorScheme;
      final wide = constraints.maxWidth >= 720;
      final type = FundusMediaTypeRegistry.forWork(
        kind: work.kind,
        contentStyle: work.contentStyle,
        contentSensitivity: work.contentSensitivity,
        providerMetadata: work.providerMetadata,
      );
      final metadata = work.providerMetadata;
      final backdrop = metadata['backdrop_url'];
      final credits = _credits(metadata['credits']);
      final genres = <String>{
        ...work.genres,
        if (metadata['genres'] case final values when values is List)
          ...values.whereType<String>(),
      }.where((value) => value.trim().isNotEmpty).toList(growable: false);
      final tags = work.tags
          .where((value) => value.trim().isNotEmpty)
          .toSet()
          .toList(growable: false);
      final details = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  work.title,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (onToggleFavorite != null)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: favorite
                      ? 'Aus Favoriten entfernen'
                      : 'Als Favorit markieren',
                  onPressed: onToggleFavorite,
                  icon: Icon(favorite ? Icons.star : Icons.star_border),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Chip(
                avatar: const Icon(Icons.movie_outlined, size: 18),
                label: Text(type?.label ?? _fallbackType(work.kind)),
              ),
              if (work.contentStyle case final style?) Chip(label: Text(style)),
              if (work.publishedYear case final year?)
                Chip(label: Text('$year')),
              if (metadata['runtime_minutes'] case final minutes
                  when minutes is num && minutes > 0)
                Chip(label: Text(_runtime(minutes.round()))),
              if (metadata['season'] case final season when season is num)
                Chip(label: Text('Staffel ${season.round()}')),
              Chip(label: Text('${work.fileCount} Datei(en)')),
            ],
          ),
          if (work.authors.isNotEmpty || work.author != 'Unbekannt') ...[
            const SizedBox(height: 12),
            Text(
              work.authors.isEmpty ? work.author : work.authors.join(', '),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
          if (genres.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final genre in genres)
                  ActionChip(
                    label: Text(genre),
                    onPressed: onSelectTag == null
                        ? null
                        : () => onSelectTag!(genre),
                  ),
              ],
            ),
          ],
          if (tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final tag in tags)
                  ActionChip(
                    avatar: const Icon(Icons.label_outline, size: 18),
                    label: Text(tag),
                    onPressed: onSelectTag == null
                        ? null
                        : () => onSelectTag!(tag),
                  ),
              ],
            ),
          ],
          if (collectionNames.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Sammlungen', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final collection in collectionNames)
                  ActionChip(
                    avatar: const Icon(Icons.folder_special_outlined, size: 18),
                    label: Text(collection),
                    onPressed: onSelectCollection == null
                        ? null
                        : () => onSelectCollection!(collection),
                  ),
              ],
            ),
          ],
          if (credits.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              'Besetzung & Crew',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final credit in credits)
                  ActionChip(
                    avatar: _avatar(credit),
                    label: Text(
                      credit.role == null || credit.role!.trim().isEmpty
                          ? credit.name
                          : '${credit.name} · ${credit.role}',
                    ),
                    onPressed: onSelectPerson == null
                        ? null
                        : () => onSelectPerson!(credit.name),
                  ),
              ],
            ),
          ],
          if (metadata.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (metadata['provider'] case final provider
                    when provider is String)
                  Chip(
                    avatar: const Icon(Icons.cloud_done_outlined, size: 18),
                    label: Text('Quelle: ${provider.toUpperCase()}'),
                  ),
                if (metadata['episode_count'] case final count
                    when count is num)
                  Chip(label: Text('${count.round()} Folgen')),
              ],
            ),
          ],
          if (work.description case final description?) ...[
            const SizedBox(height: 14),
            Text(
              description,
              maxLines: wide ? 8 : 5,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (directoryPath case final path?) ...[
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.folder_outlined, size: 18),
                const SizedBox(width: 7),
                Expanded(child: SelectableText(path)),
              ],
            ),
          ],
          if (onOpen != null ||
              onLoadMetadata != null ||
              onChangeType != null) ...[
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                if (onOpen != null)
                  SizedBox(
                    width: wide ? 280 : double.infinity,
                    child: FilledButton.icon(
                      onPressed: onOpen,
                      icon: const Icon(Icons.play_arrow),
                      label: Text(
                        work.progressPosition != null &&
                                work.progressPosition! > Duration.zero
                            ? 'Fortsetzen'
                            : 'Abspielen',
                      ),
                    ),
                  ),
                if (onLoadMetadata != null)
                  OutlinedButton.icon(
                    onPressed: onLoadMetadata,
                    icon: const Icon(Icons.cloud_download_outlined),
                    label: const Text('Details laden'),
                  ),
                if (onChangeType != null)
                  OutlinedButton.icon(
                    onPressed: onChangeType,
                    icon: const Icon(Icons.category_outlined),
                    label: const Text('Typ zuweisen'),
                  ),
              ],
            ),
          ],
        ],
      );
      final coverImage = AspectRatio(
        aspectRatio: .68,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: coverBuilder(context),
        ),
      );
      final cover = onCoverTap == null
          ? coverImage
          : InkWell(
              key: const ValueKey('video-detail-cover-action'),
              borderRadius: BorderRadius.circular(14),
              onTap: onCoverTap,
              child: coverImage,
            );
      final card = ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Stack(
          children: [
            if (backdrop is String && backdrop.trim().isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: .18,
                  child: Image.network(
                    backdrop,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    scheme.secondaryContainer.withValues(alpha: .78),
                    scheme.surfaceContainer.withValues(alpha: .92),
                  ],
                ),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 230, child: cover),
                          const SizedBox(width: 28),
                          Expanded(child: details),
                        ],
                      )
                    : Column(
                        children: [
                          SizedBox(width: 190, child: cover),
                          const SizedBox(height: 18),
                          details,
                        ],
                      ),
              ),
            ),
          ],
        ),
      );
      if (breadcrumbs.isEmpty) return card;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FundusBreadcrumbs(items: breadcrumbs, compact: true),
          const SizedBox(height: 8),
          card,
        ],
      );
    },
  );

  static String _fallbackType(String kind) =>
      switch (VideoWorkKind.base(kind)) {
        'movie' => 'Film',
        'tv' => 'Serie',
        _ => 'Video',
      };

  static String _runtime(int minutes) {
    if (minutes < 60) return '$minutes Min.';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    return remainder == 0 ? '$hours Std.' : '$hours Std. $remainder Min.';
  }

  static List<VideoProviderCredit> _credits(Object? value) => value is List
      ? value
            .map(VideoProviderCredit.fromJson)
            .whereType<VideoProviderCredit>()
            .toList(growable: false)
      : const [];

  static Widget _avatar(VideoProviderCredit credit) {
    final image = credit.imageUrl;
    if (image != null && image.isNotEmpty) {
      return CircleAvatar(backgroundImage: NetworkImage(image));
    }
    return const Icon(Icons.person_outline, size: 18);
  }
}
