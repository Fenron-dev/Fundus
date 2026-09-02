import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

enum DocumentChapterReadState { unread, current, read }

enum WorkContentAvailability { local, remote, offline, missing }

DocumentChapterReadState documentChapterReadState({
  required int chapterIndex,
  required int currentChapterIndex,
  required bool workFinished,
  MediaPosition? currentPosition,
}) {
  if (workFinished ||
      (currentChapterIndex >= 0 && chapterIndex < currentChapterIndex)) {
    return DocumentChapterReadState.read;
  }
  if (chapterIndex != currentChapterIndex) {
    return DocumentChapterReadState.unread;
  }
  if ((currentPosition?.fraction ?? 0) >= .98) {
    return DocumentChapterReadState.read;
  }
  return DocumentChapterReadState.current;
}

final class WorkContentItemViewModel {
  const WorkContentItemViewModel({
    required this.id,
    required this.title,
    required this.number,
    required this.readState,
    required this.availability,
    this.subtitle,
  });

  final String id;
  final String title;
  final int number;
  final DocumentChapterReadState readState;
  final WorkContentAvailability availability;
  final Widget? subtitle;
}

class WorkContentListTile extends StatelessWidget {
  const WorkContentListTile({
    super.key,
    required this.item,
    required this.onTap,
    this.contentPadding,
    this.selected = false,
    this.onSelectionToggle,
  });

  final WorkContentItemViewModel item;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;
  final bool selected;
  final ValueChanged<bool>? onSelectionToggle;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('work-content-${item.id}'),
    contentPadding: contentPadding,
    leading: documentChapterLeading(context, item.number, item.readState),
    title: Text(
      item.title,
      style: documentChapterTitleStyle(context, item.readState),
    ),
    subtitle: item.subtitle,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onSelectionToggle != null)
          Checkbox(
            value: selected,
            onChanged: (value) => onSelectionToggle!(value ?? false),
          ),
        _AvailabilityIcon(availability: item.availability),
        if (onTap != null) ...[
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right),
        ],
      ],
    ),
    onTap: onSelectionToggle == null
        ? onTap
        : () => onSelectionToggle!(!selected),
    onLongPress: onSelectionToggle == null
        ? null
        : () => onSelectionToggle!(!selected),
  );
}

class _AvailabilityIcon extends StatelessWidget {
  const _AvailabilityIcon({required this.availability});

  final WorkContentAvailability availability;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (availability) {
      WorkContentAvailability.local => (
        Icons.devices_outlined,
        'Auf diesem Gerät',
        Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      WorkContentAvailability.remote => (
        Icons.cloud_outlined,
        'Über Netzwerk verfügbar',
        Theme.of(context).colorScheme.primary,
      ),
      WorkContentAvailability.offline => (
        Icons.download_done,
        'Offline verfügbar',
        Theme.of(context).colorScheme.primary,
      ),
      WorkContentAvailability.missing => (
        Icons.error_outline,
        'Datei fehlt',
        Theme.of(context).colorScheme.error,
      ),
    };
    return Tooltip(
      message: label,
      child: Icon(icon, size: 19, color: color, semanticLabel: label),
    );
  }
}

Widget documentChapterLeading(
  BuildContext context,
  int number,
  DocumentChapterReadState state,
) => SizedBox(
  width: 32,
  child: switch (state) {
    DocumentChapterReadState.read => Icon(
      Icons.check_circle,
      color: Theme.of(context).colorScheme.primary,
      semanticLabel: 'Gelesen',
    ),
    DocumentChapterReadState.current => Icon(
      Icons.adjust,
      color: Theme.of(context).colorScheme.tertiary,
      semanticLabel: 'Angefangen',
    ),
    DocumentChapterReadState.unread => Text(
      '$number',
      textAlign: TextAlign.center,
    ),
  },
);

TextStyle? documentChapterTitleStyle(
  BuildContext context,
  DocumentChapterReadState state,
) => switch (state) {
  DocumentChapterReadState.read => Theme.of(
    context,
  ).textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.outline),
  DocumentChapterReadState.current => Theme.of(
    context,
  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
  DocumentChapterReadState.unread => Theme.of(
    context,
  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
};
