import 'package:flutter/material.dart';

import 'fundus_breadcrumbs.dart';
import 'media_content_schema.dart';
import 'work_detail_view_model.dart';

@immutable
final class WorkDetailHeaderAction {
  const WorkDetailHeaderAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
}

/// Shared publication header for local, downloaded, and remote works.
///
/// Transport-specific behavior stays in the caller; this widget only keeps the
/// cover, identity, favorite affordance, and primary actions visually aligned.
class WorkDetailHeader extends StatelessWidget {
  const WorkDetailHeader({
    super.key,
    required this.detail,
    required this.coverBuilder,
    this.primaryAction,
    this.secondaryAction,
    this.favorite = false,
    this.onToggleFavorite,
    this.onCoverTap,
    this.breadcrumbs = const [],
  });

  final WorkDetailViewModel detail;
  final WidgetBuilder coverBuilder;
  final WorkDetailHeaderAction? primaryAction;
  final WorkDetailHeaderAction? secondaryAction;
  final bool favorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onCoverTap;
  final List<FundusBreadcrumb> breadcrumbs;

  @override
  Widget build(BuildContext context) {
    final work = detail.summary;
    final authors = work.authors.isEmpty ? [work.author] : work.authors;
    final cover = SizedBox(
      width: 138,
      height: 190,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: coverBuilder(context),
      ),
    );
    return Column(
      children: [
        if (breadcrumbs.isNotEmpty) ...[
          FundusBreadcrumbs(items: breadcrumbs, compact: true),
          const SizedBox(height: 8),
        ],
        onCoverTap == null
            ? cover
            : InkWell(
                key: const ValueKey('work-detail-cover-action'),
                borderRadius: BorderRadius.circular(14),
                onTap: onCoverTap,
                child: cover,
              ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                work.title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (onToggleFavorite != null) ...[
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('work-detail-favorite-action'),
                onPressed: onToggleFavorite,
                tooltip: favorite
                    ? 'Aus Favoriten entfernen'
                    : 'Als Favorit markieren',
                icon: Icon(favorite ? Icons.star : Icons.star_border),
              ),
            ],
          ],
        ),
        if (authors.isNotEmpty && authors.any((value) => value.isNotEmpty))
          Text(
            authors.where((value) => value.isNotEmpty).join(', '),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            Chip(
              avatar: Icon(
                _kindIcon(
                  work.kind,
                  contentStyle: work.contentStyle,
                  contentSensitivity: work.contentSensitivity,
                ),
                size: 18,
              ),
              label: Text(
                _kindLabel(
                  work.kind,
                  contentStyle: work.contentStyle,
                  contentSensitivity: work.contentSensitivity,
                ),
              ),
            ),
            Chip(label: Text('${work.fileCount} Datei(en)')),
            if (work.status == 'incomplete')
              const Chip(label: Text('Unvollständig'))
            else if (!work.available)
              const Chip(label: Text('Dateien fehlen'))
            else if (detail.isRemote && work.offline)
              const Chip(label: Text('Offline verfügbar')),
          ],
        ),
        if (primaryAction != null || secondaryAction != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              if (primaryAction case final action?)
                Expanded(child: _primaryButton(action)),
              if (primaryAction != null && secondaryAction != null)
                const SizedBox(width: 10),
              if (secondaryAction case final action?)
                Expanded(child: _secondaryButton(action)),
            ],
          ),
        ],
      ],
    );
  }

  Widget _primaryButton(WorkDetailHeaderAction action) => FilledButton.icon(
    key: const ValueKey('work-detail-primary-action'),
    onPressed: action.onPressed,
    icon: Icon(action.icon),
    label: Text(action.label),
  );

  Widget _secondaryButton(WorkDetailHeaderAction action) =>
      FilledButton.tonalIcon(
        key: const ValueKey('work-detail-secondary-action'),
        onPressed: action.onPressed,
        icon: Icon(action.icon),
        label: Text(action.label),
      );

  String _kindLabel(
    String kind, {
    String? contentStyle,
    String? contentSensitivity,
  }) =>
      FundusMediaTypeRegistry.forWork(
        kind: kind,
        contentStyle: contentStyle,
        contentSensitivity: contentSensitivity,
        providerMetadata: detail.summary.providerMetadata,
      )?.label ??
      switch (kind) {
        'audiobook' => 'Hörbuch',
        'ebook' => 'E-Book/PDF',
        'webnovel' => 'Webnovel',
        'manga' => 'Manga/Comic',
        'image' => 'Bildsammlung',
        'document' => 'Dokument',
        'ttrpg_product' => 'TTRPG-Produkt',
        'archive' => 'Archiv',
        _ => kind,
      };

  IconData _kindIcon(
    String kind, {
    String? contentStyle,
    String? contentSensitivity,
  }) {
    final registryIcon = FundusMediaTypeRegistry.forWork(
      kind: kind,
      contentStyle: contentStyle,
      contentSensitivity: contentSensitivity,
      providerMetadata: detail.summary.providerMetadata,
    )?.iconKey;
    if (registryIcon != null) {
      return switch (registryIcon) {
        'movie' || 'anime_movie' || 'explicit_movie' => Icons.movie_outlined,
        'tv' || 'anime' || 'explicit' => Icons.live_tv_outlined,
        'headphones' => Icons.headphones_outlined,
        'book_open' || 'article' || 'menu_book' => Icons.menu_book_outlined,
        'casino' => Icons.casino_outlined,
        'image' => Icons.image_outlined,
        'picture_as_pdf' => Icons.picture_as_pdf_outlined,
        'archive' => Icons.archive_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
    }
    return switch (kind) {
      'audiobook' => Icons.music_note,
      'ebook' => Icons.menu_book_outlined,
      'webnovel' => Icons.chrome_reader_mode_outlined,
      'manga' => Icons.auto_stories_outlined,
      'image' => Icons.image_outlined,
      'document' => Icons.description_outlined,
      'ttrpg_product' => Icons.casino_outlined,
      'archive' => Icons.archive_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }
}
