import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import 'zip_archive_browser.dart';

const _comicImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
};

List<ZipArchiveEntry> comicBookPages(ZipArchiveSnapshot snapshot) {
  final pages = snapshot.entries
      .where(
        (entry) =>
            !entry.isDirectory &&
            _comicImageExtensions.contains(
              p.extension(entry.path).toLowerCase(),
            ),
      )
      .toList(growable: false);
  pages.sort((left, right) => _naturalCompare(left.path, right.path));
  return pages;
}

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

Future<ComicBookViewerResult?> showComicBookViewer(
  BuildContext context, {
  required String archivePath,
  int initialPage = 0,
  String? initialElementId,
  double? initialScrollOffset,
  PublicationReaderProfile initialProfile = const PublicationReaderProfile(),
  bool hasPreviousChapter = false,
  bool hasNextChapter = false,
  void Function(int page, int total)? onPageChanged,
  void Function(int page, int total, String elementId, double? scrollOffset)?
  onPositionChanged,
  ValueChanged<PublicationReaderProfile>? onProfileChanged,
}) => showDialog<ComicBookViewerResult>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _ComicBookDialog(
    archivePath: archivePath,
    initialPage: initialPage,
    initialElementId: initialElementId,
    initialScrollOffset: initialScrollOffset,
    initialProfile: initialProfile,
    hasPreviousChapter: hasPreviousChapter,
    hasNextChapter: hasNextChapter,
    onPageChanged: onPageChanged,
    onPositionChanged: onPositionChanged,
    onProfileChanged: onProfileChanged,
  ),
);

enum ComicBookViewerResult { previousChapter, nextChapter }

class _ComicBookDialog extends StatefulWidget {
  const _ComicBookDialog({
    required this.archivePath,
    required this.initialPage,
    required this.initialElementId,
    required this.initialScrollOffset,
    required this.initialProfile,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.onPageChanged,
    required this.onPositionChanged,
    required this.onProfileChanged,
  });

  final String archivePath;
  final int initialPage;
  final String? initialElementId;
  final double? initialScrollOffset;
  final PublicationReaderProfile initialProfile;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final void Function(int page, int total)? onPageChanged;
  final void Function(
    int page,
    int total,
    String elementId,
    double? scrollOffset,
  )?
  onPositionChanged;
  final ValueChanged<PublicationReaderProfile>? onProfileChanged;

  @override
  State<_ComicBookDialog> createState() => _ComicBookDialogState();
}

class _ComicBookDialogState extends State<_ComicBookDialog> {
  final _service = const ZipArchiveService();
  final Map<int, Future<String>> _extractedPages = {};
  late final Future<List<ZipArchiveEntry>> _pagesFuture = _service
      .inspect(widget.archivePath)
      .then(comicBookPages);
  PageController? _controller;
  ScrollController? _continuousController;
  final Map<int, GlobalKey> _continuousPageKeys = {};
  List<ZipArchiveEntry> _loadedPages = const [];
  int _currentPage = 0;
  double? _currentScrollOffset;
  bool _reportedInitialPage = false;
  bool _immersive = false;
  late PublicationReaderProfile _profile;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _currentScrollOffset = widget.initialScrollOffset;
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
    setState(() => _immersive = immersive);
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(
        immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
  }

  void _toggleImmersive() => _setImmersive(!_immersive);

  void _updateProfile(PublicationReaderProfile profile) {
    final structureChanged =
        profile.layout != _profile.layout ||
        profile.firstPageIsCover != _profile.firstPageIsCover;
    setState(() => _profile = profile);
    if (structureChanged) {
      _controller?.dispose();
      _controller = null;
      _continuousController?.dispose();
      _continuousController = null;
      _continuousPageKeys.clear();
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

  bool get _continuous =>
      _profile.layout == PublicationReaderLayout.continuousVertical ||
      _profile.layout == PublicationReaderLayout.webtoon;

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
      Navigator.pop(context, ComicBookViewerResult.previousChapter);
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
      Navigator.pop(context, ComicBookViewerResult.nextChapter);
    }
  }

  int _pageCount = 0;

  void _seekToPage(int page, List<List<int>> groups) {
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

  void _selectPage(
    int page,
    List<ZipArchiveEntry> pages, {
    double? scrollOffset,
  }) {
    if (page < 0 || page >= pages.length) return;
    _currentScrollOffset = scrollOffset;
    if (page == _currentPage) return;
    setState(() {
      _currentPage = page;
      _extractedPages.removeWhere(
        (cached, _) => (cached - page).abs() > _profile.preloadCount,
      );
    });
    widget.onPageChanged?.call(page, pages.length);
    widget.onPositionChanged?.call(
      page,
      pages.length,
      pages[page].path,
      scrollOffset,
    );
  }

  void _trackContinuousPosition(List<ZipArchiveEntry> pages) {
    if (!mounted || !(_continuousController?.hasClients ?? false)) return;
    final viewportCenter = MediaQuery.sizeOf(context).height / 2;
    int? closestPage;
    double? closestOffset;
    var closestDistance = double.infinity;
    for (final entry in _continuousPageKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) continue;
      final center = renderObject
          .localToGlobal(Offset(0, renderObject.size.height / 2))
          .dy;
      final distance = (center - viewportCenter).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestPage = entry.key;
        closestOffset = renderObject.size.height <= 0
            ? null
            : ((viewportCenter - renderObject.localToGlobal(Offset.zero).dy) /
                      renderObject.size.height)
                  .clamp(0, 1);
      }
    }
    if (closestPage != null) {
      _selectPage(closestPage, pages, scrollOffset: closestOffset);
    }
  }

  Widget _buildPagedReader(
    List<ZipArchiveEntry> pages,
    List<List<int>> groups,
  ) => PageView.builder(
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
          for (final page in group) Expanded(child: _buildPage(pages, page)),
        ],
      );
    },
  );

  Widget _buildContinuousReader(List<ZipArchiveEntry> pages) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight);
      return NotificationListener<OverscrollNotification>(
        onNotification: (notification) {
          if (notification.overscroll > 24 &&
              _currentPage + 1 >= pages.length &&
              widget.hasNextChapter) {
            Navigator.pop(context, ComicBookViewerResult.nextChapter);
            return true;
          }
          if (notification.overscroll < -24 &&
              _currentPage == 0 &&
              widget.hasPreviousChapter) {
            Navigator.pop(context, ComicBookViewerResult.previousChapter);
            return true;
          }
          return false;
        },
        child: ListView.builder(
          controller: _continuousController,
          padding: EdgeInsets.zero,
          itemCount: pages.length,
          itemBuilder: (context, page) => KeyedSubtree(
            key: _continuousPageKeys.putIfAbsent(page, GlobalKey.new),
            child: _buildPage(
              pages,
              page,
              continuous: true,
              viewport: viewport,
            ),
          ),
        ),
      );
    },
  );

  Widget _buildContinuousImage(File file, Size viewport) {
    final image = Image.file(
      file,
      errorBuilder: (context, error, stackTrace) => const Text(
        'Die Seite konnte nicht dargestellt werden.',
        style: TextStyle(color: Colors.white),
      ),
    );
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
    List<ZipArchiveEntry> pages,
    int page, {
    bool continuous = false,
    Size? viewport,
  }) => FutureBuilder<String>(
    future: _extractedPages.putIfAbsent(
      page,
      () => _service.extractToTemporaryFile(widget.archivePath, pages[page]),
    ),
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
      final file = File(pageSnapshot.data!);
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
            ? _buildContinuousImage(file, viewport!)
            : Center(child: image),
      );
      if (continuous) return pageContent;
      return InteractiveViewer(minScale: .5, maxScale: 6, child: pageContent);
    },
  );

  @override
  void dispose() {
    if (_continuous &&
        _currentPage >= 0 &&
        _currentPage < _loadedPages.length) {
      widget.onPositionChanged?.call(
        _currentPage,
        _loadedPages.length,
        _loadedPages[_currentPage].path,
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
      appBar: _immersive
          ? null
          : AppBar(
              leading: IconButton(
                onPressed: () => Navigator.pop(context),
                tooltip: 'Comic schließen',
                icon: const Icon(Icons.close),
              ),
              title: Text(
                p.basenameWithoutExtension(widget.archivePath),
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                IconButton(
                  onPressed: _toggleImmersive,
                  tooltip: 'Vollbild',
                  icon: const Icon(Icons.fullscreen),
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
                  ],
                ),
              ],
            ),
      body: FutureBuilder<List<ZipArchiveEntry>>(
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
              : pages.indexWhere(
                  (page) => page.path == widget.initialElementId,
                );
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
            _continuousController ??= ScrollController(
              initialScrollOffset: initial * 600,
            )..addListener(() => _trackContinuousPosition(pages));
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
                pages[initial].path,
                widget.initialScrollOffset,
              );
              if (_continuous) {
                final target = _continuousPageKeys[initial]?.currentContext;
                if (target != null) {
                  Scrollable.ensureVisible(
                    target,
                    alignment: (widget.initialScrollOffset ?? 0).clamp(0, 1),
                  );
                }
              }
            });
          }
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
              onDoubleTap: _toggleImmersive,
              child: Column(
                children: [
                  Expanded(
                    child: ColoredBox(
                      color: Colors.black,
                      child: _continuous
                          ? _buildContinuousReader(pages)
                          : _buildPagedReader(pages, groups),
                    ),
                  ),
                  if (!_immersive)
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
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
                            Text(
                              comicPageLabel(
                                groups,
                                _currentPage,
                                pages.length,
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
  webtoon,
  toggleFirstPageCover,
  fitScreen,
  fitWidth,
  fitHeight,
  original,
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

int _naturalCompare(String left, String right) {
  final leftParts = _naturalParts(left.toLowerCase());
  final rightParts = _naturalParts(right.toLowerCase());
  for (
    var index = 0;
    index < leftParts.length && index < rightParts.length;
    index++
  ) {
    final leftPart = leftParts[index];
    final rightPart = rightParts[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    final comparison = leftNumber != null && rightNumber != null
        ? leftNumber.compareTo(rightNumber)
        : leftPart.compareTo(rightPart);
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}

List<String> _naturalParts(String value) => RegExp(
  r'\d+|\D+',
).allMatches(value).map((match) => match.group(0)!).toList();
