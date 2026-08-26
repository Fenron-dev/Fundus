import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/fundus_diagnostics.dart';
import 'comic_page_source.dart';
import 'zip_archive_browser.dart';

List<ZipArchiveEntry> comicBookPages(ZipArchiveSnapshot snapshot) =>
    comicPageEntries(snapshot);

List<List<int>> comicPageGroups(
  int pageCount, {
  required PublicationReaderLayout layout,
  required bool firstPageIsCover,
}) {
  if (pageCount <= 0) return const [];
  if (layout != PublicationReaderLayout.doublePage) {
    return [
      for (var page = 0; page < pageCount; page++) [page],
    ];
  }
  final result = <List<int>>[];
  var page = 0;
  if (firstPageIsCover) {
    result.add([0]);
    page = 1;
  }
  while (page < pageCount) {
    result.add([page, if (page + 1 < pageCount) page + 1]);
    page += 2;
  }
  return result;
}

int comicPageGroupIndex(List<List<int>> groups, int page) {
  final index = groups.indexWhere((group) => group.contains(page));
  return index < 0 ? 0 : index;
}

String comicPageLabel(List<List<int>> groups, int page, int pageCount) {
  final group = groups[comicPageGroupIndex(groups, page)];
  return group.length == 1
      ? 'Seite ${group.single + 1} von $pageCount'
      : 'Seiten ${group.first + 1}–${group.last + 1} von $pageCount';
}

double comicOverallProgress({
  required int page,
  required int pageCount,
  int? chapterIndex,
  int? chapterCount,
}) {
  if (pageCount <= 0) return 0;
  final withinChapter = ((page + 1) / pageCount).clamp(0.0, 1.0);
  if (chapterIndex == null || chapterCount == null || chapterCount <= 0) {
    return withinChapter;
  }
  return ((chapterIndex + withinChapter) / chapterCount).clamp(0.0, 1.0);
}

PublicationProgressPlacement comicProgressPlacementFor(
  PublicationProgressPlacement configured,
  double viewportWidth,
) => configured == PublicationProgressPlacement.automatic
    ? viewportWidth >= 900
          ? PublicationProgressPlacement.right
          : PublicationProgressPlacement.bottom
    : configured;

bool comicShouldEvictCachedPage({
  required bool continuous,
  required int cachedPage,
  required int currentPage,
  required int preloadCount,
}) => !continuous && (cachedPage - currentPage).abs() > preloadCount;

double comicContinuousRestoreOffset({
  required int page,
  required double pageOffset,
  required List<Size?> pageSizes,
  required Size viewport,
  required PublicationReaderProfile profile,
  bool horizontal = false,
}) {
  if (pageSizes.isEmpty) return 0;
  final restoredPage = page.clamp(0, pageSizes.length - 1);

  var offset = 0.0;
  for (var index = 0; index < restoredPage; index++) {
    offset += comicContinuousPageExtent(
      pageSizes[index],
      viewport: viewport,
      profile: profile,
      horizontal: horizontal,
    );
  }
  offset +=
      pageOffset.clamp(0, 1) *
      comicContinuousPageExtent(
        pageSizes[restoredPage],
        viewport: viewport,
        profile: profile,
        horizontal: horizontal,
      );
  offset -= horizontal ? viewport.width / 2 : viewport.height / 2;
  return offset.clamp(0, double.infinity);
}

double comicContinuousPageExtent(
  Size? size, {
  required Size viewport,
  required PublicationReaderProfile profile,
  bool horizontal = false,
}) {
  if (size == null || size.width <= 0 || size.height <= 0) return 600;
  final gap = profile.layout == PublicationReaderLayout.webtoon
      ? 0.0
      : profile.pageGap;
  if (horizontal) {
    return switch (profile.pageScale) {
          PublicationPageScale.fitHeight =>
            viewport.height * size.width / size.height,
          PublicationPageScale.fitWidth ||
          PublicationPageScale.fitScreen => viewport.width,
          PublicationPageScale.original => size.width,
        } +
        gap;
  }
  return switch (profile.pageScale) {
        PublicationPageScale.fitWidth =>
          viewport.width * size.height / size.width,
        PublicationPageScale.fitHeight ||
        PublicationPageScale.fitScreen => viewport.height,
        PublicationPageScale.original => size.height,
      } +
      gap;
}

final class ComicChapterSequenceReport {
  const ComicChapterSequenceReport({
    required this.numbersByIndex,
    required this.missingNumbers,
    required this.duplicateNumbers,
  });

  final List<double?> numbersByIndex;
  final List<int> missingNumbers;
  final Set<double> duplicateNumbers;

  bool get hasIssues =>
      missingNumbers.isNotEmpty || duplicateNumbers.isNotEmpty;
}

ComicChapterSequenceReport comicChapterSequenceReport(List<String> titles) {
  final marker = RegExp(
    r'(?:kapitel|chapter|ch\.?|band|volume|vol\.?)\s*[-_:#]*\s*(\d+(?:[.,]\d+)?)',
    caseSensitive: false,
  );
  final numbers = <double?>[
    for (final title in titles)
      double.tryParse(
        (marker.firstMatch(title)?.group(1) ?? '').replaceAll(',', '.'),
      ),
  ];
  final counts = <double, int>{};
  for (final number in numbers.nonNulls) {
    counts.update(number, (count) => count + 1, ifAbsent: () => 1);
  }
  final duplicates = counts.entries
      .where((entry) => entry.value > 1)
      .map((entry) => entry.key)
      .toSet();
  final integers = counts.keys
      .where((number) => number == number.roundToDouble())
      .map((number) => number.toInt())
      .toSet();
  final missing = <int>[];
  if (integers.length >= 2) {
    final sorted = integers.toList()..sort();
    if (sorted.last - sorted.first <= 10000) {
      for (var number = sorted.first; number <= sorted.last; number++) {
        if (!integers.contains(number)) missing.add(number);
      }
    }
  }
  return ComicChapterSequenceReport(
    numbersByIndex: List.unmodifiable(numbers),
    missingNumbers: List.unmodifiable(missing),
    duplicateNumbers: Set.unmodifiable(duplicates),
  );
}

String comicChapterNumberLabel(num number) => number == number.roundToDouble()
    ? number.toInt().toString()
    : number.toString();

enum ComicReaderTapZone { left, center, right }

ComicReaderTapZone comicReaderTapZoneAt(
  double horizontalPosition,
  double viewportWidth, {
  double edgeFraction = .3,
}) {
  assert(edgeFraction >= .15 && edgeFraction <= .45);
  if (viewportWidth <= 0) return ComicReaderTapZone.center;
  final normalized = (horizontalPosition / viewportWidth).clamp(0, 1);
  if (normalized < edgeFraction) return ComicReaderTapZone.left;
  if (normalized > 1 - edgeFraction) return ComicReaderTapZone.right;
  return ComicReaderTapZone.center;
}

ComicReaderTapZone comicReaderTapZoneAtPoint(
  Offset localPosition,
  Size viewport, {
  double edgeFraction = .3,
  double verticalNavigationInset = .2,
}) {
  if (viewport.height <= 0) return ComicReaderTapZone.center;
  final normalizedY = localPosition.dy / viewport.height;
  // Keep the top and bottom bands exclusively for showing or hiding reader
  // chrome. A tap near a toolbar must never be interpreted as page navigation.
  if (normalizedY < verticalNavigationInset ||
      normalizedY > 1 - verticalNavigationInset) {
    return ComicReaderTapZone.center;
  }
  return comicReaderTapZoneAt(
    localPosition.dx,
    viewport.width,
    edgeFraction: edgeFraction,
  );
}

Future<ComicBookViewerResult?> showComicBookViewer(
  BuildContext context, {
  required ComicPageSource pageSource,
  int initialPage = 0,
  String? initialElementId,
  double? initialScrollOffset,
  PublicationReaderProfile initialProfile = const PublicationReaderProfile(),
  bool hasPreviousChapter = false,
  bool hasNextChapter = false,
  String? chapterTitle,
  int? chapterIndex,
  int? chapterCount,
  List<String> chapterTitles = const [],
  String? chapterFileId,
  List<LibraryBookmark> initialBookmarks = const [],
  void Function(int page, int total)? onPageChanged,
  void Function(int page, int total, String elementId, double? scrollOffset)?
  onPositionChanged,
  ValueChanged<PublicationReaderProfile>? onProfileChanged,
  Future<WorkAnnotations> Function(MediaPosition position, String? label)?
  onAddBookmark,
  Future<WorkAnnotations> Function(String bookmarkId)? onDeleteBookmark,
}) => showDialog<ComicBookViewerResult>(
  context: context,
  barrierDismissible: false,
  useSafeArea: false,
  builder: (context) => _ComicBookDialog(
    pageSource: pageSource,
    initialPage: initialPage,
    initialElementId: initialElementId,
    initialScrollOffset: initialScrollOffset,
    initialProfile: initialProfile,
    hasPreviousChapter: hasPreviousChapter,
    hasNextChapter: hasNextChapter,
    chapterTitle: chapterTitle,
    chapterIndex: chapterIndex,
    chapterCount: chapterCount,
    chapterTitles: chapterTitles,
    chapterFileId: chapterFileId,
    initialBookmarks: initialBookmarks,
    onPageChanged: onPageChanged,
    onPositionChanged: onPositionChanged,
    onProfileChanged: onProfileChanged,
    onAddBookmark: onAddBookmark,
    onDeleteBookmark: onDeleteBookmark,
  ),
);

enum ComicBookViewerAction {
  previousChapter,
  nextChapter,
  selectChapter,
  selectBookmark,
}

final class ComicBookViewerResult {
  const ComicBookViewerResult._(
    this.action, {
    this.chapterIndex,
    this.position,
  });

  static const previousChapter = ComicBookViewerResult._(
    ComicBookViewerAction.previousChapter,
  );
  static const nextChapter = ComicBookViewerResult._(
    ComicBookViewerAction.nextChapter,
  );

  factory ComicBookViewerResult.selectChapter(int chapterIndex) =>
      ComicBookViewerResult._(
        ComicBookViewerAction.selectChapter,
        chapterIndex: chapterIndex,
      );
  factory ComicBookViewerResult.selectBookmark(MediaPosition position) =>
      ComicBookViewerResult._(
        ComicBookViewerAction.selectBookmark,
        position: position,
      );

  final ComicBookViewerAction action;
  final int? chapterIndex;
  final MediaPosition? position;
}

class _ComicBookDialog extends StatefulWidget {
  const _ComicBookDialog({
    required this.pageSource,
    required this.initialPage,
    required this.initialElementId,
    required this.initialScrollOffset,
    required this.initialProfile,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.chapterTitle,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitles,
    required this.chapterFileId,
    required this.initialBookmarks,
    required this.onPageChanged,
    required this.onPositionChanged,
    required this.onProfileChanged,
    required this.onAddBookmark,
    required this.onDeleteBookmark,
  });

  final ComicPageSource pageSource;
  final int initialPage;
  final String? initialElementId;
  final double? initialScrollOffset;
  final PublicationReaderProfile initialProfile;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final String? chapterTitle;
  final int? chapterIndex;
  final int? chapterCount;
  final List<String> chapterTitles;
  final String? chapterFileId;
  final List<LibraryBookmark> initialBookmarks;
  final void Function(int page, int total)? onPageChanged;
  final void Function(
    int page,
    int total,
    String elementId,
    double? scrollOffset,
  )?
  onPositionChanged;
  final ValueChanged<PublicationReaderProfile>? onProfileChanged;
  final Future<WorkAnnotations> Function(MediaPosition position, String? label)?
  onAddBookmark;
  final Future<WorkAnnotations> Function(String bookmarkId)? onDeleteBookmark;

  @override
  State<_ComicBookDialog> createState() => _ComicBookDialogState();
}

class _ComicBookDialogState extends State<_ComicBookDialog> {
  final Map<int, Future<String>> _extractedPages = {};
  final Map<int, String> _extractedPagePaths = {};
  final Map<int, Size> _pageSizes = {};
  final GlobalKey _continuousViewportKey = GlobalKey();
  late final Future<List<ComicPage>> _pagesFuture;
  PageController? _controller;
  ScrollController? _continuousController;
  final Map<int, GlobalKey> _continuousPageKeys = {};
  List<ComicPage> _loadedPages = const [];
  int _currentPage = 0;
  double? _currentScrollOffset;
  bool _reportedInitialPage = false;
  bool _immersive = false;
  bool _controlsVisible = true;
  bool _chapterTransitionPending = false;
  bool _continuousTrackingReady = false;
  late PublicationReaderProfile _profile;
  late List<LibraryBookmark> _bookmarks;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _bookmarks = List.of(widget.initialBookmarks);
    _currentScrollOffset = widget.initialScrollOffset;
    _pagesFuture = _loadPages();
  }

  Future<List<ComicPage>> _loadPages() async {
    final pages = await widget.pageSource.pages();
    if (pages.isEmpty || !_continuous) return pages;
    // Continuous layouts must know every page extent before the ListView is
    // shown. Replacing fixed-height loading placeholders with the real image
    // heights changes the scroll extent above the viewport and made Webtoons
    // jump backwards (or even to the chapter start) while reading.
    await _preparePagesThrough(pages, pages.length - 1);
    return pages;
  }

  Future<void> _preparePagesThrough(
    List<ComicPage> pages,
    int targetPage,
  ) async {
    final end = (targetPage + _profile.preloadCount).clamp(0, pages.length - 1);
    final targets = [
      for (var index = 0; index <= end; index++)
        if (!_extractedPagePaths.containsKey(index)) pages[index],
    ];
    if (targets.isEmpty) return;
    final extracted = await widget.pageSource.materialize(targets);
    for (var index = 0; index <= end; index++) {
      final path = extracted[pages[index].id];
      if (path == null) continue;
      _extractedPagePaths[index] = path;
      _extractedPages[index] = Future.value(path);
      _pageSizes[index] = await _readImageSize(path);
    }
  }

  static Future<Size> _readImageSize(String path) async {
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  bool get _rightToLeft =>
      _profile.readingDirection == PublicationReadingDirection.rightToLeft;

  BoxFit get _imageFit => switch (_profile.pageScale) {
    PublicationPageScale.fitScreen => BoxFit.contain,
    PublicationPageScale.fitWidth => BoxFit.fitWidth,
    PublicationPageScale.fitHeight => BoxFit.fitHeight,
    PublicationPageScale.original => BoxFit.none,
  };

  Future<void> _setImmersive(bool immersive) async {
    if (_immersive == immersive) return;
    setState(() {
      _immersive = immersive;
      _controlsVisible = !immersive;
    });
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(
        immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
  }

  void _toggleImmersive() => _setImmersive(!_immersive);

  void _toggleControls() =>
      setState(() => _controlsVisible = !_controlsVisible);

  void _handleTap(TapUpDetails details, int pageCount) {
    final viewport = context.size ?? MediaQuery.sizeOf(context);
    var zone = comicReaderTapZoneAtPoint(
      details.localPosition,
      viewport,
      edgeFraction: _profile.tapZoneWidth,
    );
    if (_profile.invertTapZones) {
      zone = switch (zone) {
        ComicReaderTapZone.left => ComicReaderTapZone.right,
        ComicReaderTapZone.center => ComicReaderTapZone.center,
        ComicReaderTapZone.right => ComicReaderTapZone.left,
      };
    }
    unawaited(
      FundusDiagnostics.instance.record('comic_reader.tap', {
        'chapter': widget.pageSource.name,
        'source': widget.pageSource.kind.name,
        'layout': _profile.layout.name,
        'page': _currentPage,
        'page_count': pageCount,
        'scroll_offset': _currentScrollOffset,
        'zone': zone.name,
        'x': viewport.width <= 0
            ? null
            : details.localPosition.dx / viewport.width,
        'y': viewport.height <= 0
            ? null
            : details.localPosition.dy / viewport.height,
        'controls_visible_before': _controlsVisible,
      }),
    );
    switch (zone) {
      case ComicReaderTapZone.left:
        if (_canGoLeft(pageCount)) _goLeft(pageCount);
      case ComicReaderTapZone.center:
        _toggleControls();
      case ComicReaderTapZone.right:
        if (_canGoRight(pageCount)) _goRight(pageCount);
    }
  }

  void _updateProfile(PublicationReaderProfile profile) {
    final structureChanged =
        profile.layout != _profile.layout ||
        profile.firstPageIsCover != _profile.firstPageIsCover;
    final continuousExtentChanged =
        _continuous &&
        (profile.pageScale != _profile.pageScale ||
            profile.pageGap != _profile.pageGap ||
            profile.readerWidth != _profile.readerWidth ||
            profile.layout != _profile.layout);
    setState(() => _profile = profile);
    if (structureChanged || continuousExtentChanged) {
      _controller?.dispose();
      _controller = null;
      _continuousController?.dispose();
      _continuousController = null;
      _continuousPageKeys.clear();
      _continuousTrackingReady = false;
    }
    widget.onProfileChanged?.call(profile);
  }

  void _goLeft(int pageCount) => _rightToLeft ? _next(pageCount) : _previous();

  void _goRight(int pageCount) => _rightToLeft ? _previous() : _next(pageCount);

  bool _canGoLeft(int pageCount) => _rightToLeft
      ? _currentPage + 1 < pageCount || widget.hasNextChapter
      : _currentPage > 0 || widget.hasPreviousChapter;

  bool _canGoRight(int pageCount) => _rightToLeft
      ? _currentPage > 0 || widget.hasPreviousChapter
      : _currentPage + 1 < pageCount || widget.hasNextChapter;

  bool get _continuousHorizontal =>
      _profile.layout == PublicationReaderLayout.continuousHorizontal;

  bool get _continuousVertical =>
      _profile.layout == PublicationReaderLayout.continuousVertical ||
      _profile.layout == PublicationReaderLayout.webtoon;

  bool get _continuous => _continuousVertical || _continuousHorizontal;

  void _previous() {
    final groups = comicPageGroups(
      _pageCount,
      layout: _profile.layout,
      firstPageIsCover: _profile.firstPageIsCover,
    );
    final unit = comicPageGroupIndex(groups, _currentPage);
    if (unit > 0) {
      _seekToPage(groups[unit - 1].first, groups);
    } else if (widget.hasPreviousChapter) {
      _requestChapterTransition(ComicBookViewerResult.previousChapter);
    }
  }

  void _next(int pageCount) {
    final groups = comicPageGroups(
      pageCount,
      layout: _profile.layout,
      firstPageIsCover: _profile.firstPageIsCover,
    );
    final unit = comicPageGroupIndex(groups, _currentPage);
    if (unit + 1 < groups.length) {
      _seekToPage(groups[unit + 1].first, groups);
    } else if (widget.hasNextChapter) {
      _requestChapterTransition(ComicBookViewerResult.nextChapter);
    }
  }

  Future<void> _requestChapterTransition(
    ComicBookViewerResult direction,
  ) async {
    if (_chapterTransitionPending || !mounted) return;
    _chapterTransitionPending = true;
    final forward = direction.action == ComicBookViewerAction.nextChapter;
    final targetChapter = widget.chapterIndex == null
        ? null
        : widget.chapterIndex! + (forward ? 1 : -1);
    final targetTitle =
        targetChapter != null &&
            targetChapter >= 0 &&
            targetChapter < widget.chapterTitles.length
        ? widget.chapterTitles[targetChapter]
        : null;
    var approved =
        _profile.chapterTransition == PublicationChapterTransition.automatic;
    if (!approved) {
      approved =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              icon: Icon(forward ? Icons.skip_next : Icons.skip_previous),
              title: Text(
                forward
                    ? 'Nächstes Kapitel öffnen?'
                    : 'Vorheriges Kapitel öffnen?',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    forward
                        ? 'Du hast das Ende dieses Kapitels erreicht.'
                        : 'Du bist am Anfang dieses Kapitels.',
                  ),
                  if (targetTitle != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      targetTitle,
                      style: Theme.of(dialogContext).textTheme.titleMedium,
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Hier bleiben'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text(forward ? 'Weiterlesen' : 'Zurück'),
                ),
              ],
            ),
          ) ??
          false;
    }
    _chapterTransitionPending = false;
    if (approved && mounted) Navigator.pop(context, direction);
  }

  Future<void> _showChapterOverview() async {
    if (widget.chapterTitles.length < 2) return;
    final sequence = comicChapterSequenceReport(widget.chapterTitles);
    final missingPreview = sequence.missingNumbers
        .take(12)
        .map((number) => number.toString())
        .join(', ');
    final duplicatePreview = (sequence.duplicateNumbers.toList()..sort())
        .take(12)
        .map(comicChapterNumberLabel)
        .join(', ');
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: .75,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  'Kapitelübersicht',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
              ),
              if (sequence.hasIssues)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(sheetContext).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Kapitelreihenfolge prüfen'),
                            if (sequence.missingNumbers.isNotEmpty)
                              Text(
                                'Fehlend: $missingPreview'
                                '${sequence.missingNumbers.length > 12 ? ' …' : ''}',
                              ),
                            if (sequence.duplicateNumbers.isNotEmpty)
                              Text(
                                'Doppelt: $duplicatePreview'
                                '${sequence.duplicateNumbers.length > 12 ? ' …' : ''}',
                              ),
                            const SizedBox(height: 4),
                            const Text(
                              'Die Prüfung basiert auf den Kapiteltiteln und '
                              'verändert keine Datei.',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: widget.chapterTitles.length,
                  itemBuilder: (context, chapter) {
                    final selected = chapter == widget.chapterIndex;
                    final number = sequence.numbersByIndex[chapter];
                    final duplicate =
                        number != null &&
                        sequence.duplicateNumbers.contains(number);
                    return ListTile(
                      selected: selected,
                      leading: CircleAvatar(child: Text('${chapter + 1}')),
                      title: Text(
                        widget.chapterTitles[chapter],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: selected || duplicate
                          ? Text(
                              [
                                if (selected) 'Aktuelles Kapitel',
                                if (duplicate) 'Doppelte Kapitelnummer',
                              ].join(' · '),
                            )
                          : null,
                      trailing: duplicate
                          ? const Tooltip(
                              message: 'Doppelte Kapitelnummer',
                              child: Icon(Icons.warning_amber_rounded),
                            )
                          : selected
                          ? const Icon(Icons.menu_book)
                          : const Icon(Icons.chevron_right),
                      onTap: () => Navigator.pop(sheetContext, chapter),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null || selected == widget.chapterIndex) return;
    Navigator.pop(context, ComicBookViewerResult.selectChapter(selected));
  }

  Future<void> _addPageBookmark(List<ComicPage> pages) async {
    final callback = widget.onAddBookmark;
    if (callback == null || _currentPage >= pages.length) return;
    final controller = TextEditingController(text: 'Seite ${_currentPage + 1}');
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.bookmark_add_outlined),
        title: const Text('Seitenlesezeichen'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Bezeichnung',
            hintText: 'Optionaler Name',
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (label == null || !mounted) return;
    try {
      final annotations = await callback(
        MediaPosition(
          kind: MediaPositionKind.imageIndex,
          numericValue: _currentPage + 1,
          total: pages.length.toDouble(),
          fileId: widget.chapterFileId,
          chapterId: widget.chapterTitle,
          elementId: pages[_currentPage].id,
          scrollOffset: _currentScrollOffset,
          label:
              'Kapitel ${(widget.chapterIndex ?? 0) + 1} · '
              'Seite ${_currentPage + 1}',
        ),
        label.isEmpty ? null : label,
      );
      if (!mounted) return;
      setState(() => _bookmarks = List.of(annotations.bookmarks));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seitenlesezeichen gespeichert.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Das Seitenlesezeichen konnte nicht gespeichert werden.',
          ),
        ),
      );
    }
  }

  Future<void> _showPageBookmarks(
    List<ComicPage> pages,
    List<List<int>> groups,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final visibleBookmarks = _bookmarks
              .where(
                (bookmark) =>
                    bookmark.mediaPosition.kind == MediaPositionKind.imageIndex,
              )
              .toList(growable: false);
          return SafeArea(
            child: FractionallySizedBox(
              heightFactor: .65,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Text(
                      'Seitenlesezeichen',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (visibleBookmarks.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text('Noch keine Seitenlesezeichen vorhanden.'),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: visibleBookmarks.length,
                        itemBuilder: (context, index) {
                          final bookmark = visibleBookmarks[index];
                          final position = bookmark.mediaPosition;
                          return ListTile(
                            leading: const Icon(Icons.bookmark),
                            title: Text(
                              bookmark.label ??
                                  position.label ??
                                  position.displayValue,
                            ),
                            subtitle: Text(
                              '${position.chapterId ?? 'Kapitel'} · '
                              '${position.displayValue}',
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              final sameChapter =
                                  widget.chapterFileId == null ||
                                  position.fileId == widget.chapterFileId;
                              if (sameChapter) {
                                final page =
                                    ((position.numericValue ?? 1).round() - 1)
                                        .clamp(0, pages.length - 1);
                                _seekToPage(page, groups);
                                _selectPage(
                                  page,
                                  pages,
                                  scrollOffset: position.scrollOffset,
                                );
                              } else {
                                Navigator.pop(
                                  this.context,
                                  ComicBookViewerResult.selectBookmark(
                                    position,
                                  ),
                                );
                              }
                            },
                            trailing: widget.onDeleteBookmark == null
                                ? null
                                : IconButton(
                                    onPressed: () async {
                                      final annotations = await widget
                                          .onDeleteBookmark!(bookmark.id);
                                      if (!mounted) return;
                                      setState(
                                        () => _bookmarks = List.of(
                                          annotations.bookmarks,
                                        ),
                                      );
                                      setSheetState(() {});
                                    },
                                    tooltip: 'Lesezeichen löschen',
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  int _pageCount = 0;

  void _seekToPage(int page, List<List<int>> groups) {
    unawaited(
      FundusDiagnostics.instance.record('comic_reader.programmatic_seek', {
        'chapter': widget.pageSource.name,
        'source': widget.pageSource.kind.name,
        'layout': _profile.layout.name,
        'from_page': _currentPage,
        'target_page': page,
        'scroll_offset': _currentScrollOffset,
      }),
    );
    if (_continuous) {
      final target = _continuousPageKeys[page]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: 0,
        );
      } else if (_continuousController?.hasClients ?? false) {
        _continuousController!.animateTo(
          (page * 600).toDouble().clamp(
            0,
            _continuousController!.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    _controller?.animateToPage(
      comicPageGroupIndex(groups, page),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _selectPage(int page, List<ComicPage> pages, {double? scrollOffset}) {
    if (page < 0 || page >= pages.length) return;
    _currentScrollOffset = scrollOffset;
    if (page == _currentPage) return;
    setState(() {
      _currentPage = page;
      // Keep page futures stable in continuous readers. Replacing an earlier
      // image with the shorter loading placeholder changes ListView's extent
      // and makes Webtoons jump while scrolling upwards.
      if (!_continuous) {
        _extractedPages.removeWhere(
          (cached, _) => comicShouldEvictCachedPage(
            continuous: _continuous,
            cachedPage: cached,
            currentPage: page,
            preloadCount: _profile.preloadCount,
          ),
        );
      }
    });
    widget.onPageChanged?.call(page, pages.length);
    widget.onPositionChanged?.call(
      page,
      pages.length,
      pages[page].id,
      scrollOffset,
    );
    _preloadAround(page, pages);
  }

  void _preloadAround(int page, List<ComicPage> pages) {
    final start = (page - _profile.preloadCount).clamp(0, pages.length - 1);
    final end = (page + _profile.preloadCount).clamp(0, pages.length - 1);
    for (var index = start; index <= end; index++) {
      _pageFuture(index, pages[index]);
    }
  }

  Future<String> _pageFuture(int page, ComicPage entry) =>
      _extractedPages.putIfAbsent(page, () async {
        final extracted = await widget.pageSource.materialize([entry]);
        final path = extracted[entry.id];
        if (path == null) {
          throw const ZipArchiveException(
            'Die Comicseite konnte nicht materialisiert werden.',
          );
        }
        _extractedPagePaths[page] = path;
        _pageSizes[page] = await _readImageSize(path);
        return path;
      });

  Future<void> _showPageOverview(
    List<ComicPage> pages,
    List<List<int>> groups,
  ) async {
    final selectedPage = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: .82,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Seitenübersicht',
                            style: Theme.of(sheetContext).textTheme.titleLarge,
                          ),
                          Text(
                            widget.chapterTitle ??
                                p.basenameWithoutExtension(
                                  widget.pageSource.name,
                                ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Text('${pages.length} Seiten'),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    childAspectRatio: .7,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: pages.length,
                  itemBuilder: (context, page) => Material(
                    color: page == _currentPage
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => Navigator.pop(sheetContext, page),
                      child: Column(
                        children: [
                          Expanded(
                            child: FutureBuilder<String>(
                              future: _pageFuture(page, pages[page]),
                              builder: (context, snapshot) => snapshot.hasError
                                  ? const Center(
                                      child: Icon(Icons.broken_image_outlined),
                                    )
                                  : snapshot.hasData
                                  ? Image.file(
                                      File(snapshot.data!),
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                      alignment: Alignment.topCenter,
                                      errorBuilder: (_, _, _) => const Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                        ),
                                      ),
                                    )
                                  : const Center(
                                      child: CircularProgressIndicator(),
                                    ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Seite ${page + 1}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.labelLarge,
                                  ),
                                ),
                                if (page < _currentPage)
                                  const Tooltip(
                                    message: 'Bereits gelesen',
                                    child: Icon(Icons.check, size: 18),
                                  )
                                else if (page == _currentPage)
                                  const Tooltip(
                                    message: 'Aktuelle Seite',
                                    child: Icon(Icons.menu_book, size: 18),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (!_continuous) {
      _extractedPages.removeWhere(
        (cached, _) => comicShouldEvictCachedPage(
          continuous: _continuous,
          cachedPage: cached,
          currentPage: selectedPage ?? _currentPage,
          preloadCount: _profile.preloadCount,
        ),
      );
    }
    if (selectedPage == null) return;
    _seekToPage(selectedPage, groups);
    _selectPage(selectedPage, pages);
  }

  void _trackContinuousPosition(List<ComicPage> pages) {
    if (!mounted ||
        !_continuousTrackingReady ||
        !(_continuousController?.hasClients ?? false)) {
      return;
    }
    final viewportBox = _continuousViewportKey.currentContext
        ?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.attached) return;
    final viewportOrigin = viewportBox.localToGlobal(Offset.zero);
    final viewportCenter = _continuousHorizontal
        ? viewportOrigin.dx + viewportBox.size.width / 2
        : viewportOrigin.dy + viewportBox.size.height / 2;
    int? closestPage;
    double? closestOffset;
    var closestDistance = double.infinity;
    for (final entry in _continuousPageKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final origin = renderObject.localToGlobal(Offset.zero);
      final extent = _continuousHorizontal
          ? renderObject.size.width
          : renderObject.size.height;
      final start = _continuousHorizontal ? origin.dx : origin.dy;
      final center = start + extent / 2;
      final distance = (center - viewportCenter).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestPage = entry.key;
        closestOffset = extent <= 0
            ? null
            : ((viewportCenter - start) / extent).clamp(0, 1);
      }
    }
    if (closestPage != null) {
      _selectPage(closestPage, pages, scrollOffset: closestOffset);
    }
  }

  Widget _buildPagedReader(List<ComicPage> pages, List<List<int>> groups) =>
      PageView.builder(
        controller: _controller,
        reverse: _rightToLeft,
        itemCount: groups.length,
        onPageChanged: (unit) => _selectPage(groups[unit].first, pages),
        itemBuilder: (context, unit) {
          final group = _rightToLeft
              ? groups[unit].reversed.toList(growable: false)
              : groups[unit];
          if (group.length == 1) return _buildPage(pages, group.single);
          return Row(
            children: [
              for (final page in group)
                Expanded(child: _buildPage(pages, page)),
            ],
          );
        },
      );

  Widget _buildContinuousReader(List<ComicPage> pages) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      _continuousController ??= ScrollController(
        initialScrollOffset: _continuousInitialOffset(viewport),
      )..addListener(() => _trackContinuousPosition(pages));
      if (!_continuousTrackingReady) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_continuous) return;
            _continuousTrackingReady = true;
            _trackContinuousPosition(pages);
          });
        });
      }
      final nextOverscrollSign = _continuousHorizontal && _rightToLeft ? -1 : 1;
      return NotificationListener<OverscrollNotification>(
        onNotification: (notification) {
          if (notification.overscroll * nextOverscrollSign > 24 &&
              _currentPage + 1 >= pages.length &&
              widget.hasNextChapter) {
            _requestChapterTransition(ComicBookViewerResult.nextChapter);
            return true;
          }
          if (notification.overscroll * nextOverscrollSign < -24 &&
              _currentPage == 0 &&
              widget.hasPreviousChapter) {
            _requestChapterTransition(ComicBookViewerResult.previousChapter);
            return true;
          }
          return false;
        },
        child: ListView.builder(
          key: _continuousViewportKey,
          controller: _continuousController,
          scrollDirection: _continuousHorizontal
              ? Axis.horizontal
              : Axis.vertical,
          reverse: _continuousHorizontal && _rightToLeft,
          padding: EdgeInsets.zero,
          itemCount: pages.length,
          itemExtentBuilder: (page, _) => comicContinuousPageExtent(
            _pageSizes[page],
            viewport: viewport,
            profile: _profile,
            horizontal: _continuousHorizontal,
          ),
          itemBuilder: (context, page) => KeyedSubtree(
            key: _continuousPageKeys.putIfAbsent(page, GlobalKey.new),
            child: _buildPage(
              pages,
              page,
              continuous: true,
              continuousHorizontal: _continuousHorizontal,
              viewport: viewport,
            ),
          ),
        ),
      );
    },
  );

  double _continuousInitialOffset(Size viewport) {
    return comicContinuousRestoreOffset(
      page: _currentPage,
      pageOffset: _currentScrollOffset ?? 0,
      pageSizes: [
        for (var page = 0; page < _pageCount; page++) _pageSizes[page],
      ],
      viewport: viewport,
      profile: _profile,
      horizontal: _continuousHorizontal,
    );
  }

  Widget _buildContinuousImage(
    File file,
    Size viewport, {
    required bool horizontal,
  }) {
    final image = Image.file(
      file,
      errorBuilder: (context, error, stackTrace) => const Text(
        'Die Seite konnte nicht dargestellt werden.',
        style: TextStyle(color: Colors.white),
      ),
    );
    if (horizontal) {
      return switch (_profile.pageScale) {
        PublicationPageScale.fitWidth => SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: SingleChildScrollView(
            child: Image.file(
              file,
              width: viewport.width,
              fit: BoxFit.fitWidth,
            ),
          ),
        ),
        PublicationPageScale.fitHeight => Image.file(
          file,
          height: viewport.height,
          fit: BoxFit.fitHeight,
        ),
        PublicationPageScale.fitScreen => SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Image.file(file, fit: BoxFit.contain),
        ),
        PublicationPageScale.original => image,
      };
    }
    return switch (_profile.pageScale) {
      PublicationPageScale.fitWidth => SizedBox(
        width: viewport.width,
        child: Image.file(file, width: viewport.width, fit: BoxFit.fitWidth),
      ),
      PublicationPageScale.fitHeight => SizedBox(
        height: viewport.height,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: viewport.width),
            child: Center(
              child: Image.file(
                file,
                height: viewport.height,
                fit: BoxFit.fitHeight,
              ),
            ),
          ),
        ),
      ),
      PublicationPageScale.fitScreen => SizedBox(
        width: viewport.width,
        height: viewport.height,
        child: Image.file(file, fit: BoxFit.contain),
      ),
      PublicationPageScale.original => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: viewport.width),
          child: Center(child: image),
        ),
      ),
    };
  }

  Widget _buildPage(
    List<ComicPage> pages,
    int page, {
    bool continuous = false,
    bool continuousHorizontal = false,
    Size? viewport,
  }) {
    final extractedPath = _extractedPagePaths[page];
    if (extractedPath != null) {
      return _buildExtractedPage(
        File(extractedPath),
        page,
        continuous: continuous,
        continuousHorizontal: continuousHorizontal,
        viewport: viewport,
      );
    }
    return FutureBuilder<String>(
      future: _pageFuture(page, pages[page]),
      builder: (context, pageSnapshot) {
        if (pageSnapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: continuous ? 480 : null,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        if (pageSnapshot.hasError) {
          return SizedBox(
            height: continuous ? 240 : null,
            child: Center(
              child: Text(
                'Seite ${page + 1} konnte nicht geöffnet werden.',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          );
        }
        return _buildExtractedPage(
          File(pageSnapshot.data!),
          page,
          continuous: continuous,
          continuousHorizontal: continuousHorizontal,
          viewport: viewport,
        );
      },
    );
  }

  Widget _buildExtractedPage(
    File file,
    int page, {
    required bool continuous,
    required bool continuousHorizontal,
    required Size? viewport,
  }) {
    final image = Image.file(
      file,
      fit: _imageFit,
      errorBuilder: (context, error, stackTrace) => Text(
        'Seite ${page + 1} konnte nicht dargestellt werden.',
        style: const TextStyle(color: Colors.white),
      ),
    );
    final pageContent = Padding(
      padding: EdgeInsets.all(
        _profile.layout == PublicationReaderLayout.webtoon
            ? 0
            : _profile.pageGap / 2,
      ),
      child: continuous
          ? _buildContinuousImage(
              file,
              viewport!,
              horizontal: continuousHorizontal,
            )
          : Center(child: image),
    );
    if (continuous) return pageContent;
    return InteractiveViewer(minScale: .5, maxScale: 6, child: pageContent);
  }

  Widget _buildReaderSurface(List<ComicPage> pages, List<List<int>> groups) =>
      LayoutBuilder(
        builder: (context, constraints) => Center(
          child: SizedBox(
            width: constraints.maxWidth * _profile.readerWidth,
            height: constraints.maxHeight,
            child: _continuous
                ? _buildContinuousReader(pages)
                : _buildPagedReader(pages, groups),
          ),
        ),
      );

  Future<void> _showLayoutTuning() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) {
        void update(PublicationReaderProfile profile) {
          _updateProfile(profile);
          setSheetState(() {});
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Reader-Fläche',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Text('Breite: ${(_profile.readerWidth * 100).round()} %'),
                Slider(
                  value: _profile.readerWidth,
                  min: .4,
                  max: 1,
                  divisions: 12,
                  label: '${(_profile.readerWidth * 100).round()} %',
                  onChanged: (value) =>
                      update(_profile.copyWith(readerWidth: value)),
                ),
                Text(
                  _profile.layout == PublicationReaderLayout.webtoon
                      ? 'Seitenabstand: 0 px (Webtoon ist lückenlos)'
                      : 'Seitenabstand: ${_profile.pageGap.round()} px',
                ),
                Slider(
                  value: _profile.pageGap,
                  min: 0,
                  max: 64,
                  divisions: 16,
                  label: '${_profile.pageGap.round()} px',
                  onChanged: _profile.layout == PublicationReaderLayout.webtoon
                      ? null
                      : (value) => update(_profile.copyWith(pageGap: value)),
                ),
                const Divider(height: 32),
                Text(
                  'Tap-Zonen',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                _TapZonePreview(
                  edgeFraction: _profile.tapZoneWidth,
                  inverted: _profile.invertTapZones,
                ),
                const SizedBox(height: 12),
                Text(
                  'Seitliche Zone: '
                  '${(_profile.tapZoneWidth * 100).round()} % je Seite',
                ),
                Slider(
                  value: _profile.tapZoneWidth,
                  min: .15,
                  max: .45,
                  divisions: 6,
                  label: '${(_profile.tapZoneWidth * 100).round()} %',
                  onChanged: (value) =>
                      update(_profile.copyWith(tapZoneWidth: value)),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Linke und rechte Aktion umkehren'),
                  subtitle: const Text(
                    'Leserichtung und Seitenreihenfolge bleiben unverändert.',
                  ),
                  value: _profile.invertTapZones,
                  onChanged: (value) =>
                      update(_profile.copyWith(invertTapZones: value)),
                ),
                const Divider(height: 32),
                Text(
                  'Kapitelwechsel',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<PublicationChapterTransition>(
                  segments: const [
                    ButtonSegment(
                      value: PublicationChapterTransition.confirm,
                      icon: Icon(Icons.help_outline),
                      label: Text('Nachfragen'),
                    ),
                    ButtonSegment(
                      value: PublicationChapterTransition.automatic,
                      icon: Icon(Icons.skip_next),
                      label: Text('Automatisch'),
                    ),
                  ],
                  selected: {_profile.chapterTransition},
                  onSelectionChanged: (selection) => update(
                    _profile.copyWith(chapterTransition: selection.single),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Fortschrittsleiste',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<PublicationProgressPlacement>(
                  initialValue: _profile.progressPlacement,
                  decoration: const InputDecoration(
                    labelText: 'Position',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: PublicationProgressPlacement.automatic,
                      child: Text('Automatisch'),
                    ),
                    DropdownMenuItem(
                      value: PublicationProgressPlacement.bottom,
                      child: Text('Unten'),
                    ),
                    DropdownMenuItem(
                      value: PublicationProgressPlacement.left,
                      child: Text('Links'),
                    ),
                    DropdownMenuItem(
                      value: PublicationProgressPlacement.right,
                      child: Text('Rechts'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      update(_profile.copyWith(progressPlacement: value));
                    }
                  },
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => update(
                      _profile.copyWith(
                        readerWidth: 1,
                        pageGap: 8,
                        tapZoneWidth: .3,
                        invertTapZones: false,
                        chapterTransition: PublicationChapterTransition.confirm,
                        progressPlacement:
                            PublicationProgressPlacement.automatic,
                      ),
                    ),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('Layout und Tap-Zonen zurücksetzen'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  @override
  void dispose() {
    if (_continuous &&
        _currentPage >= 0 &&
        _currentPage < _loadedPages.length) {
      widget.onPositionChanged?.call(
        _currentPage,
        _loadedPages.length,
        _loadedPages[_currentPage].id,
        _currentScrollOffset,
      );
    }
    _controller?.dispose();
    _continuousController?.dispose();
    if (_immersive && (Platform.isAndroid || Platform.isIOS)) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      extendBodyBehindAppBar: true,
      extendBody: true,
      appBar: !_controlsVisible
          ? null
          : AppBar(
              leading: IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: 'Comic schließen',
                icon: const Icon(Icons.close),
              ),
              title: Text(
                p.basenameWithoutExtension(widget.pageSource.name),
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (widget.onAddBookmark != null)
                  IconButton(
                    onPressed: _loadedPages.isEmpty
                        ? null
                        : () => _addPageBookmark(_loadedPages),
                    tooltip: 'Seitenlesezeichen hinzufügen',
                    icon: const Icon(Icons.bookmark_add_outlined),
                  ),
                if (_bookmarks.any(
                  (bookmark) =>
                      bookmark.mediaPosition.kind ==
                      MediaPositionKind.imageIndex,
                ))
                  IconButton(
                    onPressed: _loadedPages.isEmpty
                        ? null
                        : () => _showPageBookmarks(
                            _loadedPages,
                            comicPageGroups(
                              _loadedPages.length,
                              layout: _profile.layout,
                              firstPageIsCover: _profile.firstPageIsCover,
                            ),
                          ),
                    tooltip: 'Seitenlesezeichen anzeigen',
                    icon: const Icon(Icons.bookmarks_outlined),
                  ),
                if (widget.chapterTitles.length > 1)
                  IconButton(
                    onPressed: _showChapterOverview,
                    tooltip: 'Kapitelübersicht',
                    icon: const Icon(Icons.format_list_numbered),
                  ),
                IconButton(
                  onPressed: _toggleImmersive,
                  tooltip: _immersive ? 'Vollbild verlassen' : 'Vollbild',
                  icon: Icon(
                    _immersive ? Icons.fullscreen_exit : Icons.fullscreen,
                  ),
                ),
                PopupMenuButton<_ComicReaderSettingAction>(
                  tooltip: 'Reader-Einstellungen',
                  icon: const Icon(Icons.tune),
                  onSelected: (action) {
                    switch (action) {
                      case _ComicReaderSettingAction.leftToRight:
                        _updateProfile(
                          _profile.copyWith(
                            readingDirection:
                                PublicationReadingDirection.leftToRight,
                          ),
                        );
                      case _ComicReaderSettingAction.rightToLeft:
                        _updateProfile(
                          _profile.copyWith(
                            readingDirection:
                                PublicationReadingDirection.rightToLeft,
                          ),
                        );
                      case _ComicReaderSettingAction.singlePage:
                        _updateProfile(
                          _profile.copyWith(
                            layout: PublicationReaderLayout.singlePage,
                          ),
                        );
                      case _ComicReaderSettingAction.doublePage:
                        _updateProfile(
                          _profile.copyWith(
                            layout: PublicationReaderLayout.doublePage,
                          ),
                        );
                      case _ComicReaderSettingAction.continuousVertical:
                        _updateProfile(
                          _profile.copyWith(
                            layout: PublicationReaderLayout.continuousVertical,
                          ),
                        );
                      case _ComicReaderSettingAction.continuousHorizontal:
                        _updateProfile(
                          _profile.copyWith(
                            layout:
                                PublicationReaderLayout.continuousHorizontal,
                          ),
                        );
                      case _ComicReaderSettingAction.webtoon:
                        _updateProfile(
                          _profile.copyWith(
                            layout: PublicationReaderLayout.webtoon,
                          ),
                        );
                      case _ComicReaderSettingAction.toggleFirstPageCover:
                        _updateProfile(
                          _profile.copyWith(
                            firstPageIsCover: !_profile.firstPageIsCover,
                          ),
                        );
                      case _ComicReaderSettingAction.fitScreen:
                        _updateProfile(
                          _profile.copyWith(
                            pageScale: PublicationPageScale.fitScreen,
                          ),
                        );
                      case _ComicReaderSettingAction.fitWidth:
                        _updateProfile(
                          _profile.copyWith(
                            pageScale: PublicationPageScale.fitWidth,
                          ),
                        );
                      case _ComicReaderSettingAction.fitHeight:
                        _updateProfile(
                          _profile.copyWith(
                            pageScale: PublicationPageScale.fitHeight,
                          ),
                        );
                      case _ComicReaderSettingAction.original:
                        _updateProfile(
                          _profile.copyWith(
                            pageScale: PublicationPageScale.original,
                          ),
                        );
                      case _ComicReaderSettingAction.layoutTuning:
                        _showLayoutTuning();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      enabled: false,
                      child: Text('Leserichtung'),
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.leftToRight,
                      'Links nach rechts',
                      !_rightToLeft,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.rightToLeft,
                      'Rechts nach links (Manga)',
                      _rightToLeft,
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      enabled: false,
                      child: Text('Seitenmodus'),
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.singlePage,
                      'Einzelseite',
                      _profile.layout == PublicationReaderLayout.singlePage,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.doublePage,
                      'Doppelseite',
                      _profile.layout == PublicationReaderLayout.doublePage,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.continuousVertical,
                      'Kontinuierlich vertikal',
                      _profile.layout ==
                          PublicationReaderLayout.continuousVertical,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.continuousHorizontal,
                      'Kontinuierlich horizontal',
                      _profile.layout ==
                          PublicationReaderLayout.continuousHorizontal,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.webtoon,
                      'Webtoon / Long-Strip',
                      _profile.layout == PublicationReaderLayout.webtoon,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.toggleFirstPageCover,
                      'Erste Seite ist Cover',
                      _profile.firstPageIsCover,
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      enabled: false,
                      child: Text('Skalierung'),
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.fitScreen,
                      'An Bildschirm anpassen',
                      _profile.pageScale == PublicationPageScale.fitScreen,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.fitWidth,
                      'An Breite anpassen',
                      _profile.pageScale == PublicationPageScale.fitWidth,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.fitHeight,
                      'An Höhe anpassen',
                      _profile.pageScale == PublicationPageScale.fitHeight,
                    ),
                    _profileItem(
                      _ComicReaderSettingAction.original,
                      'Originalgröße',
                      _profile.pageScale == PublicationPageScale.original,
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _ComicReaderSettingAction.layoutTuning,
                      child: Row(
                        children: [
                          const Icon(Icons.tune, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Breite ${(_profile.readerWidth * 100).round()} % · '
                            'Abstand ${_profile.pageGap.round()} px',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
      body: FutureBuilder<List<ComicPage>>(
        future: _pagesFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                snapshot.error is ZipArchiveException
                    ? (snapshot.error! as ZipArchiveException).message
                    : 'Der Comic konnte nicht gelesen werden.',
                textAlign: TextAlign.center,
              ),
            );
          }
          final pages = snapshot.data!;
          if (pages.isEmpty) {
            return const Center(
              child: Text('Das CBZ-Archiv enthält keine unterstützten Bilder.'),
            );
          }
          _loadedPages = pages;
          final anchoredPage = widget.initialElementId == null
              ? -1
              : pages.indexWhere((page) => page.id == widget.initialElementId);
          final initial =
              (anchoredPage >= 0 ? anchoredPage : widget.initialPage).clamp(
                0,
                pages.length - 1,
              );
          _pageCount = pages.length;
          final groups = comicPageGroups(
            pages.length,
            layout: _profile.layout,
            firstPageIsCover: _profile.firstPageIsCover,
          );
          if (_continuous) {
            if (_currentPage == 0 && initial > 0) _currentPage = initial;
          } else {
            _controller ??= PageController(
              initialPage: comicPageGroupIndex(groups, initial),
            );
          }
          if (_currentPage == 0 && initial > 0) _currentPage = initial;
          if (!_reportedInitialPage) {
            _reportedInitialPage = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onPageChanged?.call(initial, pages.length);
              widget.onPositionChanged?.call(
                initial,
                pages.length,
                pages[initial].id,
                widget.initialScrollOffset,
              );
              _preloadAround(initial, pages);
            });
          }
          final progressValue = comicOverallProgress(
            page: _currentPage,
            pageCount: pages.length,
            chapterIndex: widget.chapterIndex,
            chapterCount: widget.chapterCount,
          );
          final progressPlacement = comicProgressPlacementFor(
            _profile.progressPlacement,
            MediaQuery.sizeOf(context).width,
          );
          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                _goLeft(pages.length);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                _goRight(pages.length);
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.f11) {
                _toggleImmersive();
                return KeyEventResult.handled;
              }
              if (_immersive && event.logicalKey == LogicalKeyboardKey.escape) {
                _setImmersive(false);
                return KeyEventResult.handled;
              }
              if (_continuous &&
                  (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                      event.logicalKey == LogicalKeyboardKey.pageUp)) {
                _previous();
                return KeyEventResult.handled;
              }
              if (_continuous &&
                  (event.logicalKey == LogicalKeyboardKey.arrowDown ||
                      event.logicalKey == LogicalKeyboardKey.pageDown)) {
                _next(pages.length);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) => _handleTap(details, pages.length),
              onDoubleTap: _toggleImmersive,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black,
                      child: _buildReaderSurface(pages, groups),
                    ),
                  ),
                  if (_controlsVisible &&
                      progressPlacement == PublicationProgressPlacement.left)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 4,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: LinearProgressIndicator(value: progressValue),
                      ),
                    ),
                  if (_controlsVisible &&
                      progressPlacement == PublicationProgressPlacement.right)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 4,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: LinearProgressIndicator(value: progressValue),
                      ),
                    ),
                  if (_controlsVisible)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: SafeArea(
                          top: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (progressPlacement ==
                                  PublicationProgressPlacement.bottom)
                                LinearProgressIndicator(
                                  minHeight: 3,
                                  value: progressValue,
                                ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    IconButton(
                                      onPressed: _canGoLeft(pages.length)
                                          ? () => _goLeft(pages.length)
                                          : null,
                                      tooltip: _rightToLeft
                                          ? 'Nächste Seite'
                                          : 'Vorherige Seite',
                                      icon: const Icon(Icons.chevron_left),
                                    ),
                                    IconButton(
                                      onPressed: () =>
                                          _showPageOverview(pages, groups),
                                      tooltip: 'Seitenübersicht',
                                      icon: const Icon(Icons.grid_view),
                                    ),
                                    Expanded(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (widget.chapterCount != null)
                                            Text(
                                              'Kapitel ${(widget.chapterIndex ?? 0) + 1} '
                                              'von ${widget.chapterCount}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelMedium,
                                            ),
                                          Text(
                                            comicPageLabel(
                                              groups,
                                              _currentPage,
                                              pages.length,
                                            ),
                                            textAlign: TextAlign.center,
                                          ),
                                          if (widget.chapterTitle
                                              case final title?)
                                            Text(
                                              title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelSmall,
                                            ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      onPressed: _canGoRight(pages.length)
                                          ? () => _goRight(pages.length)
                                          : null,
                                      tooltip: _rightToLeft
                                          ? 'Vorherige Seite'
                                          : 'Nächste Seite',
                                      icon: const Icon(Icons.chevron_right),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}

enum _ComicReaderSettingAction {
  leftToRight,
  rightToLeft,
  singlePage,
  doublePage,
  continuousVertical,
  continuousHorizontal,
  webtoon,
  toggleFirstPageCover,
  fitScreen,
  fitWidth,
  fitHeight,
  original,
  layoutTuning,
}

PopupMenuItem<_ComicReaderSettingAction> _profileItem(
  _ComicReaderSettingAction value,
  String label,
  bool selected,
) => PopupMenuItem(
  value: value,
  child: Row(
    children: [
      Icon(selected ? Icons.check : null, size: 18),
      const SizedBox(width: 8),
      Text(label),
    ],
  ),
);

class _TapZonePreview extends StatelessWidget {
  const _TapZonePreview({required this.edgeFraction, required this.inverted});

  final double edgeFraction;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final edgeFlex = (edgeFraction * 1000).round();
    final centerFlex = 1000 - edgeFlex * 2;
    final scheme = Theme.of(context).colorScheme;

    Widget zone(IconData icon, String label, {required bool center}) =>
        Container(
          color: center ? scheme.secondaryContainer : scheme.primaryContainer,
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 2),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        );

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            Expanded(
              flex: edgeFlex,
              child: zone(
                inverted ? Icons.arrow_forward : Icons.arrow_back,
                'Links',
                center: false,
              ),
            ),
            Expanded(
              flex: centerFlex,
              child: zone(Icons.visibility, 'Bedienung', center: true),
            ),
            Expanded(
              flex: edgeFlex,
              child: zone(
                inverted ? Icons.arrow_back : Icons.arrow_forward,
                'Rechts',
                center: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
