import 'package:flutter/material.dart';

enum WorkDetailSection { info, files, chapters, notes, similar }

enum WorkAnnotationSection { notes, annotations }

/// Shared navigation for publication detail pages, independent of storage or
/// transport. Keeping the enum typed prevents local and remote tabs from
/// silently drifting into different orders.
class WorkDetailSectionSelector extends StatelessWidget {
  const WorkDetailSectionSelector({
    super.key,
    required this.selected,
    required this.onChanged,
    this.contentLabel = 'Kapitel',
  });

  final WorkDetailSection selected;
  final ValueChanged<WorkDetailSection> onChanged;
  final String contentLabel;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SegmentedButton<WorkDetailSection>(
      key: const ValueKey('work-detail-section-selector'),
      showSelectedIcon: false,
      segments: [
        ButtonSegment(value: WorkDetailSection.info, label: Text('Info')),
        ButtonSegment(value: WorkDetailSection.files, label: Text('Dateien')),
        ButtonSegment(
          value: WorkDetailSection.chapters,
          label: Text(contentLabel),
        ),
        ButtonSegment(value: WorkDetailSection.notes, label: Text('Notizen')),
        ButtonSegment(value: WorkDetailSection.similar, label: Text('Ähnlich')),
      ],
      selected: {selected},
      onSelectionChanged: (value) => onChanged(value.single),
    ),
  );
}

class WorkAnnotationSectionSelector extends StatelessWidget {
  const WorkAnnotationSectionSelector({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final WorkAnnotationSection selected;
  final ValueChanged<WorkAnnotationSection> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<WorkAnnotationSection>(
    key: const ValueKey('work-annotation-section-selector'),
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(value: WorkAnnotationSection.notes, label: Text('Notizen')),
      ButtonSegment(
        value: WorkAnnotationSection.annotations,
        label: Text('Lesezeichen & Highlights'),
      ),
    ],
    selected: {selected},
    onSelectionChanged: (value) => onChanged(value.single),
  );
}
