import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

String formatAnnotationDate(DateTime value) {
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

class WorkNotesList extends StatelessWidget {
  const WorkNotesList({
    super.key,
    required this.notes,
    this.composer,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 20),
  });

  final List<LibraryNote> notes;
  final Widget? composer;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => ListView(
    key: const ValueKey('work-notes-list'),
    padding: padding,
    children: [
      if (notes.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Noch keine Notizen vorhanden.',
            textAlign: TextAlign.center,
          ),
        )
      else
        for (final note in notes) WorkNoteCard(note: note),
      if (composer case final value?) ...[const SizedBox(height: 8), value],
    ],
  );
}

class WorkNoteCard extends StatelessWidget {
  const WorkNoteCard({super.key, required this.note});

  final LibraryNote note;

  @override
  Widget build(BuildContext context) => Card(
    key: ValueKey('work-note-${note.id}'),
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            formatAnnotationDate(note.createdAt),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 6),
          SelectableText(note.markdown),
        ],
      ),
    ),
  );
}

class WorkAnnotationList extends StatelessWidget {
  const WorkAnnotationList({
    super.key,
    required this.bookmarks,
    required this.highlights,
    this.onOpenBookmark,
    this.onOpenHighlight,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  final List<LibraryBookmark> bookmarks;
  final List<LibraryHighlight> highlights;
  final ValueChanged<LibraryBookmark>? onOpenBookmark;
  final ValueChanged<LibraryHighlight>? onOpenHighlight;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (bookmarks.isEmpty && highlights.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Noch keine Lesezeichen oder Highlights vorhanden.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView(
      key: const ValueKey('work-annotation-list'),
      padding: padding,
      children: [
        for (final bookmark in bookmarks)
          ListTile(
            key: ValueKey('work-bookmark-${bookmark.id}'),
            leading: const Icon(Icons.bookmark_outline),
            title: Text(bookmark.label ?? bookmark.displayPosition),
            subtitle: Text(_bookmarkSubtitle(bookmark)),
            trailing: onOpenBookmark == null
                ? null
                : const Icon(Icons.chevron_right),
            onTap: onOpenBookmark == null
                ? null
                : () => onOpenBookmark!(bookmark),
          ),
        for (final highlight in highlights)
          ListTile(
            key: ValueKey('work-highlight-${highlight.id}'),
            leading: const Icon(Icons.border_color_outlined),
            title: Text(
              highlight.quote,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(_highlightSubtitle(highlight)),
            trailing: onOpenHighlight == null
                ? null
                : const Icon(Icons.chevron_right),
            onTap: onOpenHighlight == null
                ? null
                : () => onOpenHighlight!(highlight),
          ),
      ],
    );
  }

  static String _bookmarkSubtitle(LibraryBookmark bookmark) {
    final parts = <String>[
      bookmark.mediaPosition.chapterId ?? 'Textstelle',
      bookmark.displayPosition,
      formatAnnotationDate(bookmark.createdAt),
      ?_nonEmpty(bookmark.note),
    ];
    return parts.join(' · ');
  }

  static String _highlightSubtitle(LibraryHighlight highlight) {
    final parts = <String>[
      highlight.mediaPosition.chapterId ?? 'Textstelle',
      highlight.mediaPosition.displayValue,
      formatAnnotationDate(highlight.createdAt),
      ?_nonEmpty(highlight.note),
    ];
    return parts.join(' · ');
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
