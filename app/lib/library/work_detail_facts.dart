import 'package:flutter/material.dart';
import 'package:fundus_core/fundus_core.dart';

import 'work_detail_view_model.dart';

class WorkDetailFacts extends StatelessWidget {
  const WorkDetailFacts({
    super.key,
    required this.detail,
    this.progress,
    this.directoryPath,
  });

  final WorkDetailViewModel detail;
  final MediaPosition? progress;
  final String? directoryPath;

  @override
  Widget build(BuildContext context) {
    final work = detail.summary;
    final authors = work.authors.isEmpty ? [work.author] : work.authors;
    final source = [
      work.sourceServerName,
      work.sourceLibraryName,
    ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');
    final position = progress ?? work.mediaProgress;
    return Column(
      children: [
        _fact(
          icon: Icons.person_outline,
          label: authors.length == 1 ? 'Autor' : 'Autoren',
          value: authors.join(', '),
        ),
        if (work.narrators.isNotEmpty)
          _fact(
            icon: Icons.mic_none,
            label: work.narrators.length == 1 ? 'Sprecher' : 'Sprecher',
            value: work.narrators.join(', '),
          ),
        if (work.series case final series?)
          _fact(
            icon: Icons.library_books_outlined,
            label: 'Serie',
            value: work.seriesSequence == null
                ? series
                : '$series · Band ${_formatNumber(work.seriesSequence!)}',
          ),
        if (work.language case final language?)
          _fact(icon: Icons.language, label: 'Sprache', value: language),
        if (work.publisher != null || work.publishedYear != null)
          _fact(
            icon: Icons.business_outlined,
            label: 'Veröffentlichung',
            value: [
              work.publisher,
              if (work.publishedYear case final year?) '$year',
            ].whereType<String>().join(' · '),
          ),
        _fact(
          icon: Icons.folder_copy_outlined,
          label: 'Umfang',
          value: '${work.fileCount} Datei(en)',
        ),
        _fact(
          key: const ValueKey('work-detail-availability'),
          icon: _availabilityIcon(work),
          label: 'Verfügbarkeit',
          value: _availabilityLabel(work),
        ),
        if (source.isNotEmpty)
          _fact(
            key: const ValueKey('work-detail-source'),
            icon: Icons.dns_outlined,
            label: 'Quelle',
            value: source,
          ),
        if (directoryPath case final path? when path.trim().isNotEmpty)
          _fact(
            key: const ValueKey('work-detail-directory'),
            icon: Icons.folder_outlined,
            label: 'Dateipfad',
            value: path,
          ),
        if (work.progressFinished ||
            position != null ||
            work.progressPosition != null)
          _fact(
            key: const ValueKey('work-detail-progress'),
            icon: work.progressFinished
                ? Icons.check_circle_outline
                : Icons.history,
            label: 'Fortschritt',
            value: _progressLabel(work, position),
          ),
      ],
    );
  }

  Widget _fact({
    Key? key,
    required IconData icon,
    required String label,
    required String value,
  }) => ListTile(
    key: key,
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(label),
    subtitle: Text(value),
  );

  String _availabilityLabel(LibraryWorkSummary work) {
    if (work.status == 'incomplete') return 'Offline · unvollständig';
    if (!work.available) return 'Dateien fehlen';
    if (detail.isRemote && work.offline) return 'Remote · offline verfügbar';
    if (detail.isRemote) return 'Remote';
    if (detail.isOffline || work.offline) return 'Offline verfügbar';
    return 'Lokal verfügbar';
  }

  IconData _availabilityIcon(LibraryWorkSummary work) {
    if (work.status == 'incomplete' || !work.available) {
      return Icons.warning_amber_rounded;
    }
    if (detail.isRemote && !work.offline) return Icons.cloud_outlined;
    if (detail.isOffline || work.offline) return Icons.download_done;
    return Icons.folder_outlined;
  }

  String _progressLabel(LibraryWorkSummary work, MediaPosition? position) {
    if (work.progressFinished) return 'Abgeschlossen';
    if (position != null) {
      final base = position.displayValue;
      final fraction = position.fraction;
      return fraction == null ? base : '$base · ${(fraction * 100).round()} %';
    }
    final elapsed = work.progressPosition;
    if (elapsed == null) return 'Begonnen';
    final total = work.progressDuration;
    return total == null
        ? _formatDuration(elapsed)
        : '${_formatDuration(elapsed)} / ${_formatDuration(total)}';
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours.toString().padLeft(2, '0');
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  String _formatNumber(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
