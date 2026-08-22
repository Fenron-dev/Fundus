import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

import 'publication_reader_settings.dart';

enum ReflowTextReaderAction { previousChapter, nextChapter, selectChapter }

final class ReflowTextReaderResult {
  const ReflowTextReaderResult._(
    this.action, [
    this.chapterIndex,
    this.targetPosition,
  ]);

  static const previousChapter = ReflowTextReaderResult._(
    ReflowTextReaderAction.previousChapter,
  );
  static const nextChapter = ReflowTextReaderResult._(
    ReflowTextReaderAction.nextChapter,
  );

  factory ReflowTextReaderResult.selectChapter(
    int index, {
    MediaPosition? targetPosition,
  }) => ReflowTextReaderResult._(
    ReflowTextReaderAction.selectChapter,
    index,
    targetPosition,
  );

  final ReflowTextReaderAction action;
  final int? chapterIndex;
  final MediaPosition? targetPosition;
}

final class ReflowReaderSearchResult {
  const ReflowReaderSearchResult({
    required this.chapterIndex,
    required this.chapterTitle,
    required this.position,
    required this.snippet,
  });

  final int chapterIndex;
  final String chapterTitle;
  final MediaPosition position;
  final String snippet;
}

typedef ReflowReaderSearch =
    Future<List<ReflowReaderSearchResult>> Function(String query);

typedef ReflowAddBookmark =
    Future<WorkAnnotations> Function(MediaPosition position, String? label);
typedef ReflowAddHighlight =
    Future<WorkAnnotations> Function(
      MediaPosition position,
      String quote,
      String color,
      String? note,
    );
typedef ReflowDeleteAnnotation =
    Future<WorkAnnotations> Function(String annotationId);

bool supportsInternalReflowTextReader(String path) => const {
  '.html',
  '.htm',
  '.txt',
  '.md',
  '.markdown',
}.contains(p.extension(path).toLowerCase());

Future<ReflowTextReaderResult?> showReflowTextReader(
  BuildContext context, {
  required String path,
  required String title,
  MediaPosition? initialPosition,
  String? fileId,
  String? relativePath,
  String? positionChapterId,
  int chapterIndex = 0,
  int chapterCount = 1,
  List<String> chapterTitles = const [],
  List<String> chapterIds = const [],
  bool hasPreviousChapter = false,
  bool hasNextChapter = false,
  ReflowReaderProfile initialProfile = const ReflowReaderProfile(),
  void Function(MediaPosition position)? onPositionChanged,
  void Function(ReflowReaderProfile profile)? onProfileChanged,
  Future<void> Function(ReflowReaderProfile profile)? onSaveAsDefault,
  Future<ReflowReaderProfile> Function()? onResetWorkProfile,
  ReflowReaderSearch? onSearch,
  List<LibraryBookmark> initialBookmarks = const [],
  List<LibraryHighlight> initialHighlights = const [],
  ReflowAddBookmark? onAddBookmark,
  ReflowAddHighlight? onAddHighlight,
  ReflowDeleteAnnotation? onDeleteBookmark,
  ReflowDeleteAnnotation? onDeleteHighlight,
  Future<void> Function()? onExportAnnotations,
}) async {
  final file = File(path);
  if (!await file.exists()) {
    throw const ReflowTextReaderException(
      'Die Webnovel-Datei ist nicht mehr am gespeicherten Ort vorhanden.',
    );
  }
  final length = await file.length();
  if (length > 32 * 1024 * 1024) {
    throw const ReflowTextReaderException(
      'Diese einzelne Textdatei ist für den ersten internen Reader zu groß.',
    );
  }
  final source = utf8.decode(await file.readAsBytes(), allowMalformed: true);
  final format = switch (p.extension(path).toLowerCase()) {
    '.html' || '.htm' => ReflowSourceFormat.html,
    '.md' || '.markdown' => ReflowSourceFormat.markdown,
    _ => ReflowSourceFormat.plainText,
  };
  final document = ReflowDocument.parse(source, format: format);
  if (!context.mounted) return null;
  return showReflowDocumentReader(
    context,
    document: document,
    title: title,
    initialPosition: initialPosition,
    fileId: fileId,
    relativePath: relativePath,
    positionChapterId: positionChapterId,
    chapterIndex: chapterIndex,
    chapterCount: chapterCount,
    chapterTitles: chapterTitles,
    chapterIds: chapterIds,
    hasPreviousChapter: hasPreviousChapter,
    hasNextChapter: hasNextChapter,
    initialProfile: initialProfile,
    onPositionChanged: onPositionChanged,
    onProfileChanged: onProfileChanged,
    onSaveAsDefault: onSaveAsDefault,
    onResetWorkProfile: onResetWorkProfile,
    onSearch: onSearch,
    initialBookmarks: initialBookmarks,
    initialHighlights: initialHighlights,
    onAddBookmark: onAddBookmark,
    onAddHighlight: onAddHighlight,
    onDeleteBookmark: onDeleteBookmark,
    onDeleteHighlight: onDeleteHighlight,
    onExportAnnotations: onExportAnnotations,
  );
}

Future<ReflowTextReaderResult?> showReflowDocumentReader(
  BuildContext context, {
  required ReflowDocument document,
  required String title,
  MediaPosition? initialPosition,
  String? fileId,
  String? relativePath,
  String? positionChapterId,
  int chapterIndex = 0,
  int chapterCount = 1,
  List<String> chapterTitles = const [],
  List<String> chapterIds = const [],
  bool hasPreviousChapter = false,
  bool hasNextChapter = false,
  ReflowReaderProfile initialProfile = const ReflowReaderProfile(),
  void Function(MediaPosition position)? onPositionChanged,
  void Function(ReflowReaderProfile profile)? onProfileChanged,
  Future<void> Function(ReflowReaderProfile profile)? onSaveAsDefault,
  Future<ReflowReaderProfile> Function()? onResetWorkProfile,
  ReflowReaderSearch? onSearch,
  List<LibraryBookmark> initialBookmarks = const [],
  List<LibraryHighlight> initialHighlights = const [],
  ReflowAddBookmark? onAddBookmark,
  ReflowAddHighlight? onAddHighlight,
  ReflowDeleteAnnotation? onDeleteBookmark,
  ReflowDeleteAnnotation? onDeleteHighlight,
  Future<void> Function()? onExportAnnotations,
}) {
  return showDialog<ReflowTextReaderResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ReflowTextReaderDialog(
      document: document,
      title: title,
      initialPosition: initialPosition,
      fileId: fileId,
      relativePath: relativePath,
      positionChapterId: positionChapterId,
      chapterIndex: chapterIndex,
      chapterCount: chapterCount,
      chapterTitles: chapterTitles,
      chapterIds: chapterIds,
      hasPreviousChapter: hasPreviousChapter,
      hasNextChapter: hasNextChapter,
      initialProfile: initialProfile,
      onPositionChanged: onPositionChanged,
      onProfileChanged: onProfileChanged,
      onSaveAsDefault: onSaveAsDefault,
      onResetWorkProfile: onResetWorkProfile,
      onSearch: onSearch,
      initialBookmarks: initialBookmarks,
      initialHighlights: initialHighlights,
      onAddBookmark: onAddBookmark,
      onAddHighlight: onAddHighlight,
      onDeleteBookmark: onDeleteBookmark,
      onDeleteHighlight: onDeleteHighlight,
      onExportAnnotations: onExportAnnotations,
    ),
  );
}

final class ReflowTextReaderException implements Exception {
  const ReflowTextReaderException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ReflowTextReaderDialog extends StatefulWidget {
  const _ReflowTextReaderDialog({
    required this.document,
    required this.title,
    required this.initialPosition,
    required this.fileId,
    required this.relativePath,
    required this.positionChapterId,
    required this.chapterIndex,
    required this.chapterCount,
    required this.chapterTitles,
    required this.chapterIds,
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.initialProfile,
    required this.onPositionChanged,
    required this.onProfileChanged,
    required this.onSaveAsDefault,
    required this.onResetWorkProfile,
    required this.onSearch,
    required this.initialBookmarks,
    required this.initialHighlights,
    required this.onAddBookmark,
    required this.onAddHighlight,
    required this.onDeleteBookmark,
    required this.onDeleteHighlight,
    required this.onExportAnnotations,
  });

  final ReflowDocument document;
  final String title;
  final MediaPosition? initialPosition;
  final String? fileId;
  final String? relativePath;
  final String? positionChapterId;
  final int chapterIndex;
  final int chapterCount;
  final List<String> chapterTitles;
  final List<String> chapterIds;
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final ReflowReaderProfile initialProfile;
  final void Function(MediaPosition position)? onPositionChanged;
  final void Function(ReflowReaderProfile profile)? onProfileChanged;
  final Future<void> Function(ReflowReaderProfile profile)? onSaveAsDefault;
  final Future<ReflowReaderProfile> Function()? onResetWorkProfile;
  final ReflowReaderSearch? onSearch;
  final List<LibraryBookmark> initialBookmarks;
  final List<LibraryHighlight> initialHighlights;
  final ReflowAddBookmark? onAddBookmark;
  final ReflowAddHighlight? onAddHighlight;
  final ReflowDeleteAnnotation? onDeleteBookmark;
  final ReflowDeleteAnnotation? onDeleteHighlight;
  final Future<void> Function()? onExportAnnotations;

  @override
  State<_ReflowTextReaderDialog> createState() =>
      _ReflowTextReaderDialogState();
}

class _ReflowTextReaderDialogState extends State<_ReflowTextReaderDialog> {
  final _scrollController = ScrollController();
  final _viewportKey = GlobalKey();
  late final List<GlobalKey> _paragraphKeys;
  Timer? _reportTimer;
  bool _restoring = true;
  int _restoreEpoch = 0;
  late ReflowReaderProfile _profile;
  MediaPosition? _lastPosition;
  late List<LibraryBookmark> _bookmarks;
  late List<LibraryHighlight> _highlights;
  String? _selectedText;
  bool _chromeVisible = true;
  Offset? _readerTapStart;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    _bookmarks = List.of(widget.initialBookmarks);
    _highlights = List.of(widget.initialHighlights);
    _paragraphKeys = [
      for (var index = 0; index < widget.document.paragraphs.length; index++)
        GlobalKey(),
    ];
    _scrollController.addListener(_schedulePositionReport);
    final epoch = ++_restoreEpoch;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restorePosition(widget.initialPosition, epoch: epoch),
    );
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _reportCurrentPosition();
    _scrollController.dispose();
    super.dispose();
  }

  void _schedulePositionReport() {
    if (_restoring) return;
    _reportTimer?.cancel();
    _reportTimer = Timer(
      const Duration(milliseconds: 220),
      _reportCurrentPosition,
    );
    if (mounted) setState(() {});
  }

  Future<void> _restorePosition(
    MediaPosition? position, {
    required int epoch,
  }) async {
    if (epoch != _restoreEpoch) return;
    if (!mounted || widget.document.paragraphs.isEmpty) {
      _restoring = false;
      return;
    }
    final resolved = widget.document.resolve(position);
    final targetContext =
        _paragraphKeys[resolved.paragraphIndex].currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(targetContext, alignment: 0);
      if (!mounted || epoch != _restoreEpoch) return;
      final box =
          _paragraphKeys[resolved.paragraphIndex].currentContext
                  ?.findRenderObject()
              as RenderBox?;
      if (box != null && _scrollController.hasClients) {
        final target =
            (_scrollController.offset + box.size.height * resolved.innerOffset)
                .clamp(0, _scrollController.position.maxScrollExtent)
                .toDouble();
        _scrollController.jumpTo(target);
      }
    }
    if (epoch != _restoreEpoch) return;
    _restoring = false;
    _reportCurrentPosition();
    if (mounted) setState(() {});
  }

  MediaPosition? _currentPosition() {
    if (widget.document.paragraphs.isEmpty) return null;
    final anchor = _visibleAnchor();
    return widget.document.positionFor(
      paragraphIndex: anchor.index,
      innerOffset: anchor.offset,
      fileId: widget.fileId,
      chapterId: widget.positionChapterId ?? widget.title,
      key: widget.relativePath,
    );
  }

  ({int index, double offset}) _visibleAnchor() {
    if (widget.document.paragraphs.isEmpty) return (index: 0, offset: 0);
    final viewport =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    final viewportTop = viewport?.localToGlobal(Offset.zero).dy ?? 0;
    var bestIndex = 0;
    var bestOffset = 0.0;
    for (var index = 0; index < _paragraphKeys.length; index++) {
      final box =
          _paragraphKeys[index].currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.attached) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      final bottom = top + box.size.height;
      if (bottom <= viewportTop) continue;
      bestIndex = index;
      bestOffset = box.size.height <= 0
          ? 0
          : ((viewportTop - top) / box.size.height).clamp(0, 1).toDouble();
      break;
    }
    return (index: bestIndex, offset: bestOffset);
  }

  void _reportCurrentPosition() {
    if (_restoring || widget.document.paragraphs.isEmpty) return;
    final position = _currentPosition();
    if (position == null) return;
    if (_lastPosition?.elementId == position.elementId &&
        ((_lastPosition?.scrollOffset ?? 0) - (position.scrollOffset ?? 0))
                .abs() <
            .005) {
      return;
    }
    _lastPosition = position;
    widget.onPositionChanged?.call(position);
  }

  void _applyProfile(ReflowReaderProfile profile) {
    final anchor = _currentPosition();
    _restoring = true;
    setState(() => _profile = profile);
    final epoch = ++_restoreEpoch;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restorePosition(anchor, epoch: epoch),
    );
  }

  void _toggleChrome(Offset position) {
    final width = MediaQuery.sizeOf(context).width;
    if (position.dx < width * .25 || position.dx > width * .75) {
      return;
    }
    setState(() => _chromeVisible = !_chromeVisible);
  }

  Future<void> _showReaderSettings() async {
    var draft = _profile;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(ReflowReaderProfile value) {
            draft = value;
            setSheetState(() {});
            _applyProfile(value);
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Lesedarstellung',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<ReflowFontFamily>(
                    initialValue: draft.fontFamily,
                    decoration: const InputDecoration(labelText: 'Schriftart'),
                    items: [
                      for (final family in ReflowFontFamily.values)
                        DropdownMenuItem(
                          value: family,
                          child: Text(
                            family.label,
                            style: TextStyle(fontFamily: family.familyName),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        update(draft.copyWith(fontFamily: value));
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _ReaderValueSlider(
                    label: 'Schriftgröße',
                    valueLabel: '${draft.fontSize.toStringAsFixed(0)} pt',
                    value: draft.fontSize,
                    min: 12,
                    max: 40,
                    divisions: 28,
                    onChanged: (value) =>
                        update(draft.copyWith(fontSize: value)),
                  ),
                  _ReaderValueSlider(
                    label: 'Textbreite',
                    valueLabel: '${draft.contentWidth.toStringAsFixed(0)} px',
                    value: draft.contentWidth,
                    min: 320,
                    max: 1400,
                    divisions: 54,
                    onChanged: (value) =>
                        update(draft.copyWith(contentWidth: value)),
                  ),
                  _ReaderValueSlider(
                    label: 'Zeilenabstand',
                    valueLabel: draft.lineHeight.toStringAsFixed(2),
                    value: draft.lineHeight,
                    min: 1.1,
                    max: 2.4,
                    divisions: 26,
                    onChanged: (value) =>
                        update(draft.copyWith(lineHeight: value)),
                  ),
                  _ReaderValueSlider(
                    label: 'Absatzabstand',
                    valueLabel:
                        '${draft.paragraphSpacing.toStringAsFixed(0)} px',
                    value: draft.paragraphSpacing,
                    min: 0,
                    max: 48,
                    divisions: 24,
                    onChanged: (value) =>
                        update(draft.copyWith(paragraphSpacing: value)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sepia'),
                    value: draft.sepia,
                    onChanged: (value) => update(draft.copyWith(sepia: value)),
                  ),
                  if (widget.onSaveAsDefault != null ||
                      widget.onResetWorkProfile != null) ...[
                    const Divider(height: 28),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        if (widget.onSaveAsDefault != null)
                          OutlinedButton.icon(
                            onPressed: () async {
                              await widget.onSaveAsDefault!(draft);
                              if (!sheetContext.mounted) return;
                              ScaffoldMessenger.of(sheetContext).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Als Standard für EPUBs und Webnovels gespeichert.',
                                  ),
                                ),
                              );
                            },
                            icon: const Icon(Icons.bookmark_add_outlined),
                            label: const Text('Als Standard speichern'),
                          ),
                        if (widget.onResetWorkProfile != null)
                          TextButton.icon(
                            onPressed: () async {
                              final fallback =
                                  await widget.onResetWorkProfile!();
                              if (!mounted) return;
                              update(fallback);
                            },
                            icon: const Icon(Icons.restart_alt),
                            label: const Text('Titelwerte zurücksetzen'),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) widget.onProfileChanged?.call(_profile);
  }

  Future<void> _showChapters() async {
    if (widget.chapterTitles.length <= 1) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView.builder(
          itemCount: widget.chapterTitles.length,
          itemBuilder: (context, index) => ListTile(
            selected: index == widget.chapterIndex,
            leading: Text('${index + 1}'),
            title: Text(widget.chapterTitles[index]),
            trailing: index == widget.chapterIndex
                ? const Icon(Icons.menu_book)
                : null,
            onTap: () => Navigator.pop(context, index),
          ),
        ),
      ),
    );
    if (!mounted || selected == null || selected == widget.chapterIndex) return;
    _reportCurrentPosition();
    Navigator.pop(context, ReflowTextReaderResult.selectChapter(selected));
  }

  Future<List<ReflowReaderSearchResult>> _search(String query) async {
    if (widget.onSearch != null) return widget.onSearch!(query);
    return [
      for (final match in widget.document.search(query))
        ReflowReaderSearchResult(
          chapterIndex: widget.chapterIndex,
          chapterTitle: widget.title,
          position: widget.document.positionFor(
            paragraphIndex: match.paragraphIndex,
            innerOffset: match.innerOffset,
            fileId: widget.fileId,
            chapterId: widget.positionChapterId ?? widget.title,
            key: widget.relativePath,
          ),
          snippet: match.snippet,
        ),
    ];
  }

  Future<void> _showSearch() async {
    final selected = await showModalBottomSheet<ReflowReaderSearchResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ReflowSearchSheet(
        onSearch: _search,
        searchesWholeBook: widget.onSearch != null,
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.chapterIndex == widget.chapterIndex) {
      _restoring = true;
      final epoch = ++_restoreEpoch;
      await _restorePosition(selected.position, epoch: epoch);
      return;
    }
    _reportCurrentPosition();
    Navigator.pop(
      context,
      ReflowTextReaderResult.selectChapter(
        selected.chapterIndex,
        targetPosition: selected.position,
      ),
    );
  }

  Future<void> _addBookmark() async {
    final callback = widget.onAddBookmark;
    final position = _currentPosition();
    if (callback == null || position == null) return;
    final controller = TextEditingController(
      text: position.label ?? position.displayValue,
    );
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.bookmark_add_outlined),
        title: const Text('Textlesezeichen'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Bezeichnung'),
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
    if (label == null || !mounted) return;
    final annotations = await callback(position, label.isEmpty ? null : label);
    if (!mounted) return;
    setState(() => _bookmarks = List.of(annotations.bookmarks));
  }

  ({MediaPosition position, String quote})? _selectedHighlight() {
    final quote = _selectedText?.trim();
    if (quote == null || quote.isEmpty) return null;
    final firstLine = quote
        .split(RegExp(r'\s*\n+\s*'))
        .firstWhere((value) => value.isNotEmpty, orElse: () => quote);
    final anchor = _visibleAnchor();
    final order = <int>[
      anchor.index,
      for (
        var distance = 1;
        distance < widget.document.paragraphs.length;
        distance++
      ) ...[
        if (anchor.index + distance < widget.document.paragraphs.length)
          anchor.index + distance,
        if (anchor.index - distance >= 0) anchor.index - distance,
      ],
    ];
    for (final index in order) {
      final paragraph = widget.document.paragraphs[index];
      final offset = paragraph.text.toLowerCase().indexOf(
        firstLine.toLowerCase(),
      );
      if (offset < 0) continue;
      return (
        position: widget.document.positionFor(
          paragraphIndex: index,
          innerOffset: paragraph.text.isEmpty
              ? 0
              : offset / paragraph.text.length,
          fileId: widget.fileId,
          chapterId: widget.positionChapterId ?? widget.title,
          key: widget.relativePath,
        ),
        quote: quote,
      );
    }
    return null;
  }

  Future<void> _addHighlight() async {
    final callback = widget.onAddHighlight;
    final selected = _selectedHighlight();
    if (callback == null || selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Markiere zuerst einen zusammenhängenden Textabschnitt.',
          ),
        ),
      );
      return;
    }
    final noteController = TextEditingController();
    var color = '#FFF176';
    final result = await showDialog<({String color, String? note})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.border_color_outlined),
          title: const Text('Text hervorheben'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                selected.quote,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                children: [
                  for (final candidate in const [
                    '#FFF176',
                    '#A5D6A7',
                    '#90CAF9',
                    '#F8BBD0',
                  ])
                    ChoiceChip(
                      selected: color == candidate,
                      avatar: CircleAvatar(
                        backgroundColor: _highlightColor(candidate),
                      ),
                      label: const Text(''),
                      onSelected: (_) =>
                          setDialogState(() => color = candidate),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: noteController,
                decoration: const InputDecoration(
                  labelText: 'Notiz (optional)',
                  border: OutlineInputBorder(),
                ),
                minLines: 2,
                maxLines: 4,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, (
                color: color,
                note: noteController.text.trim().isEmpty
                    ? null
                    : noteController.text.trim(),
              )),
              child: const Text('Hervorheben'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    final annotations = await callback(
      selected.position,
      selected.quote,
      result.color,
      result.note,
    );
    if (!mounted) return;
    setState(() {
      _highlights = List.of(annotations.highlights);
      _selectedText = null;
    });
  }

  Color _highlightColor(String value) {
    final normalized = value.replaceFirst('#', '');
    final parsed = int.tryParse(normalized, radix: 16) ?? 0xfff176;
    return Color(0xff000000 | parsed);
  }

  Future<void> _jumpToAnnotation(MediaPosition position) async {
    final sameChapter =
        position.chapterId == (widget.positionChapterId ?? widget.title);
    if (sameChapter) {
      _restoring = true;
      final epoch = ++_restoreEpoch;
      await _restorePosition(position, epoch: epoch);
      return;
    }
    final index = widget.chapterIds.indexOf(position.chapterId ?? '');
    if (index < 0) return;
    _reportCurrentPosition();
    Navigator.pop(
      context,
      ReflowTextReaderResult.selectChapter(index, targetPosition: position),
    );
  }

  Future<void> _showAnnotations() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: FractionallySizedBox(
            heightFactor: .72,
            child: Column(
              children: [
                ListTile(
                  title: const Text('Lesezeichen & Markierungen'),
                  trailing: widget.onExportAnnotations == null
                      ? null
                      : IconButton(
                          onPressed: widget.onExportAnnotations,
                          tooltip: 'Annotationen exportieren',
                          icon: const Icon(Icons.ios_share_outlined),
                        ),
                ),
                Expanded(
                  child: _bookmarks.isEmpty && _highlights.isEmpty
                      ? const Center(
                          child: Text('Noch keine Annotationen vorhanden.'),
                        )
                      : ListView(
                          children: [
                            for (final bookmark in _bookmarks)
                              ListTile(
                                leading: const Icon(Icons.bookmark),
                                title: Text(
                                  bookmark.label ?? bookmark.displayPosition,
                                ),
                                subtitle: Text(
                                  bookmark.mediaPosition.chapterId ??
                                      'Textstelle',
                                ),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  _jumpToAnnotation(bookmark.mediaPosition);
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
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                              ),
                            for (final highlight in _highlights)
                              ListTile(
                                leading: Icon(
                                  Icons.format_color_fill,
                                  color: _highlightColor(highlight.color),
                                ),
                                title: Text(
                                  highlight.quote,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: highlight.note == null
                                    ? Text(
                                        highlight.mediaPosition.chapterId ??
                                            'Textstelle',
                                      )
                                    : Text(highlight.note!),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  _jumpToAnnotation(highlight.mediaPosition);
                                },
                                trailing: widget.onDeleteHighlight == null
                                    ? null
                                    : IconButton(
                                        onPressed: () async {
                                          final annotations = await widget
                                              .onDeleteHighlight!(highlight.id);
                                          if (!mounted) return;
                                          setState(
                                            () => _highlights = List.of(
                                              annotations.highlights,
                                            ),
                                          );
                                          setSheetState(() {});
                                        },
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildParagraph(int index, TextStyle style) {
    final paragraph = widget.document.paragraphs[index];
    final ranges = <({int start, int end, Color color})>[];
    for (final highlight in _highlights) {
      final position = highlight.mediaPosition;
      if (position.chapterId != (widget.positionChapterId ?? widget.title) ||
          position.elementId != paragraph.id) {
        continue;
      }
      final quote = highlight.quote.split(RegExp(r'\s*\n+\s*')).first.trim();
      if (quote.isEmpty) continue;
      var start = ((position.scrollOffset ?? 0) * paragraph.text.length)
          .round();
      start = start.clamp(0, paragraph.text.length);
      final expectedEnd = (start + quote.length).clamp(
        0,
        paragraph.text.length,
      );
      if (paragraph.text.substring(start, expectedEnd).toLowerCase() !=
          quote.toLowerCase()) {
        start = paragraph.text.toLowerCase().indexOf(quote.toLowerCase());
      }
      if (start < 0) continue;
      ranges.add((
        start: start,
        end: (start + quote.length).clamp(0, paragraph.text.length),
        color: _highlightColor(highlight.color),
      ));
    }
    if (ranges.isEmpty) return Text(paragraph.text, style: style);
    ranges.sort((left, right) => left.start.compareTo(right.start));
    final spans = <TextSpan>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.start < cursor) continue;
      if (range.start > cursor) {
        spans.add(
          TextSpan(text: paragraph.text.substring(cursor, range.start)),
        );
      }
      spans.add(
        TextSpan(
          text: paragraph.text.substring(range.start, range.end),
          style: TextStyle(
            backgroundColor: range.color.withValues(alpha: .62),
            color: const Color(0xff201a00),
          ),
        ),
      );
      cursor = range.end;
    }
    if (cursor < paragraph.text.length) {
      spans.add(TextSpan(text: paragraph.text.substring(cursor)));
    }
    return Text.rich(TextSpan(children: spans), style: style);
  }

  @override
  Widget build(BuildContext context) {
    final progress =
        _lastPosition?.fraction ?? widget.initialPosition?.fraction;
    final colors = Theme.of(context).colorScheme;
    final background = _profile.sepia
        ? const Color(0xfff2e7cf)
        : colors.surfaceContainerLowest;
    final foreground = _profile.sepia
        ? const Color(0xff392f23)
        : colors.onSurface;
    return Dialog.fullscreen(
      child: Scaffold(
        backgroundColor: background,
        appBar: !_chromeVisible
            ? null
            : AppBar(
                backgroundColor: background,
                leading: IconButton(
                  onPressed: () {
                    _reportCurrentPosition();
                    Navigator.pop(context);
                  },
                  tooltip: 'Reader schließen',
                  icon: const Icon(Icons.close),
                ),
                title: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, overflow: TextOverflow.ellipsis),
                    if (widget.chapterCount > 1)
                      Text(
                        'Kapitel ${widget.chapterIndex + 1} von ${widget.chapterCount}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                  ],
                ),
                actions: [
                  if (widget.onAddBookmark != null)
                    IconButton(
                      onPressed: _addBookmark,
                      tooltip: 'Lesezeichen hinzufügen',
                      icon: const Icon(Icons.bookmark_add_outlined),
                    ),
                  if (widget.onAddHighlight != null)
                    IconButton(
                      onPressed: _addHighlight,
                      tooltip: 'Auswahl hervorheben',
                      icon: const Icon(Icons.border_color_outlined),
                    ),
                  if (_bookmarks.isNotEmpty || _highlights.isNotEmpty)
                    IconButton(
                      onPressed: _showAnnotations,
                      tooltip: 'Lesezeichen und Markierungen',
                      icon: const Icon(Icons.collections_bookmark_outlined),
                    ),
                  IconButton(
                    onPressed: _showSearch,
                    tooltip: 'Im Buch suchen',
                    icon: const Icon(Icons.search),
                  ),
                  if (widget.chapterTitles.length > 1)
                    IconButton(
                      onPressed: _showChapters,
                      tooltip: 'Kapitelübersicht',
                      icon: const Icon(Icons.list_alt),
                    ),
                  IconButton(
                    onPressed: _showReaderSettings,
                    tooltip: 'Lesedarstellung',
                    icon: const Icon(Icons.text_fields),
                  ),
                ],
                bottom: progress == null
                    ? null
                    : PreferredSize(
                        preferredSize: const Size.fromHeight(3),
                        child: LinearProgressIndicator(value: progress),
                      ),
              ),
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (event) => _readerTapStart = event.localPosition,
          onPointerUp: (event) {
            final start = _readerTapStart;
            _readerTapStart = null;
            if (start != null && (event.localPosition - start).distance <= 12) {
              _toggleChrome(event.localPosition);
            }
          },
          onPointerCancel: (_) => _readerTapStart = null,
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              if (!_scrollController.hasClients) return KeyEventResult.ignored;
              final delta = switch (event.logicalKey) {
                LogicalKeyboardKey.pageUp => -500.0,
                LogicalKeyboardKey.pageDown => 500.0,
                _ => null,
              };
              if (delta == null) return KeyEventResult.ignored;
              _scrollController.animateTo(
                (_scrollController.offset + delta).clamp(
                  0,
                  _scrollController.position.maxScrollExtent,
                ),
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
              );
              return KeyEventResult.handled;
            },
            child: KeyedSubtree(
              key: _viewportKey,
              child: SelectionArea(
                onSelectionChanged: (selection) {
                  final value = selection?.plainText.trim();
                  if (value != null && value.isNotEmpty) _selectedText = value;
                },
                child: SingleChildScrollView(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                    vertical: 36,
                    horizontal: 20,
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: _profile.contentWidth,
                      ),
                      child: widget.document.paragraphs.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(40),
                              child: Text(
                                'Dieses Kapitel enthält keinen lesbaren Text.',
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (
                                  var index = 0;
                                  index < widget.document.paragraphs.length;
                                  index++
                                )
                                  Padding(
                                    key: _paragraphKeys[index],
                                    padding: EdgeInsets.only(
                                      bottom: _profile.paragraphSpacing,
                                    ),
                                    child: _buildParagraph(
                                      index,
                                      TextStyle(
                                        color: foreground,
                                        fontFamily:
                                            _profile.fontFamily.familyName,
                                        fontSize: _profile.fontSize,
                                        height: _profile.lineHeight,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        bottomNavigationBar:
            !_chromeVisible ||
                (!widget.hasPreviousChapter && !widget.hasNextChapter)
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: widget.hasPreviousChapter
                            ? () {
                                _reportCurrentPosition();
                                Navigator.pop(
                                  context,
                                  ReflowTextReaderResult.previousChapter,
                                );
                              }
                            : null,
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Vorheriges Kapitel'),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: widget.hasNextChapter
                            ? () {
                                _reportCurrentPosition();
                                Navigator.pop(
                                  context,
                                  ReflowTextReaderResult.nextChapter,
                                );
                              }
                            : null,
                        iconAlignment: IconAlignment.end,
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('Nächstes Kapitel'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _ReflowSearchSheet extends StatefulWidget {
  const _ReflowSearchSheet({
    required this.onSearch,
    required this.searchesWholeBook,
  });

  final ReflowReaderSearch onSearch;
  final bool searchesWholeBook;

  @override
  State<_ReflowSearchSheet> createState() => _ReflowSearchSheetState();
}

class _ReflowSearchSheetState extends State<_ReflowSearchSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  int _searchEpoch = 0;
  bool _loading = false;
  List<ReflowReaderSearchResult> _results = const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _scheduleSearch(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _run(query));
  }

  Future<void> _run(String query) async {
    final epoch = ++_searchEpoch;
    final normalized = query.trim();
    if (normalized.isEmpty) {
      if (mounted) setState(() => _results = const []);
      return;
    }
    setState(() => _loading = true);
    final results = await widget.onSearch(normalized);
    if (!mounted || epoch != _searchEpoch) return;
    setState(() {
      _loading = false;
      _results = results;
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: widget.searchesWholeBook
                    ? 'Im ganzen Buch suchen'
                    : 'Im Kapitel suchen',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _controller.clear();
                          _scheduleSearch('');
                          setState(() {});
                        },
                        tooltip: 'Suche leeren',
                        icon: const Icon(Icons.clear),
                      ),
              ),
              onChanged: (value) {
                _scheduleSearch(value);
                setState(() {});
              },
              onSubmitted: _run,
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: _controller.text.trim().isEmpty
                ? const Center(
                    child: Text(
                      'Suchbegriff eingeben, um Textstellen zu finden.',
                    ),
                  )
                : !_loading && _results.isEmpty
                ? const Center(child: Text('Keine Treffer gefunden.'))
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      return ListTile(
                        leading: const Icon(Icons.subject),
                        title: Text(result.chapterTitle),
                        subtitle: Text(
                          result.snippet,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => Navigator.pop(context, result),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _ReaderValueSlider extends StatelessWidget {
  const _ReaderValueSlider({
    required this.label,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text(valueLabel, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: valueLabel,
        onChanged: onChanged,
      ),
    ],
  );
}
