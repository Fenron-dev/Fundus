import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fundus_core/fundus_core.dart';
import 'package:path/path.dart' as p;

enum ReflowTextReaderAction { previousChapter, nextChapter, selectChapter }

final class ReflowTextReaderResult {
  const ReflowTextReaderResult._(this.action, [this.chapterIndex]);

  static const previousChapter = ReflowTextReaderResult._(
    ReflowTextReaderAction.previousChapter,
  );
  static const nextChapter = ReflowTextReaderResult._(
    ReflowTextReaderAction.nextChapter,
  );

  factory ReflowTextReaderResult.selectChapter(int index) =>
      ReflowTextReaderResult._(ReflowTextReaderAction.selectChapter, index);

  final ReflowTextReaderAction action;
  final int? chapterIndex;
}

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
  bool hasPreviousChapter = false,
  bool hasNextChapter = false,
  void Function(MediaPosition position)? onPositionChanged,
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
    hasPreviousChapter: hasPreviousChapter,
    hasNextChapter: hasNextChapter,
    onPositionChanged: onPositionChanged,
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
  bool hasPreviousChapter = false,
  bool hasNextChapter = false,
  void Function(MediaPosition position)? onPositionChanged,
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
      hasPreviousChapter: hasPreviousChapter,
      hasNextChapter: hasNextChapter,
      onPositionChanged: onPositionChanged,
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
    required this.hasPreviousChapter,
    required this.hasNextChapter,
    required this.onPositionChanged,
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
  final bool hasPreviousChapter;
  final bool hasNextChapter;
  final void Function(MediaPosition position)? onPositionChanged;

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
  double _fontSize = 19;
  double _lineHeight = 1.55;
  double _contentWidth = 760;
  bool _sepia = false;
  MediaPosition? _lastPosition;

  @override
  void initState() {
    super.initState();
    _paragraphKeys = [
      for (var index = 0; index < widget.document.paragraphs.length; index++)
        GlobalKey(),
    ];
    _scrollController.addListener(_schedulePositionReport);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restorePosition());
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

  Future<void> _restorePosition() async {
    if (!mounted || widget.document.paragraphs.isEmpty) {
      _restoring = false;
      return;
    }
    final resolved = widget.document.resolve(widget.initialPosition);
    final targetContext =
        _paragraphKeys[resolved.paragraphIndex].currentContext;
    if (targetContext != null) {
      await Scrollable.ensureVisible(targetContext, alignment: 0);
      if (!mounted) return;
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
    _restoring = false;
    _reportCurrentPosition();
    if (mounted) setState(() {});
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
    final anchor = _visibleAnchor();
    final position = widget.document.positionFor(
      paragraphIndex: anchor.index,
      innerOffset: anchor.offset,
      fileId: widget.fileId,
      chapterId: widget.positionChapterId ?? widget.title,
      key: widget.relativePath,
    );
    if (_lastPosition?.elementId == position.elementId &&
        ((_lastPosition?.scrollOffset ?? 0) - (position.scrollOffset ?? 0))
                .abs() <
            .005) {
      return;
    }
    _lastPosition = position;
    widget.onPositionChanged?.call(position);
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

  @override
  Widget build(BuildContext context) {
    final progress =
        _lastPosition?.fraction ?? widget.initialPosition?.fraction;
    final colors = Theme.of(context).colorScheme;
    final background = _sepia
        ? const Color(0xfff2e7cf)
        : colors.surfaceContainerLowest;
    final foreground = _sepia ? const Color(0xff392f23) : colors.onSurface;
    return Dialog.fullscreen(
      child: Scaffold(
        backgroundColor: background,
        appBar: AppBar(
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
            if (widget.chapterTitles.length > 1)
              IconButton(
                onPressed: _showChapters,
                tooltip: 'Kapitelübersicht',
                icon: const Icon(Icons.list_alt),
              ),
            PopupMenuButton<String>(
              tooltip: 'Lesedarstellung',
              icon: const Icon(Icons.text_fields),
              onSelected: (value) => setState(() {
                switch (value) {
                  case 'smaller':
                    _fontSize = (_fontSize - 1).clamp(12, 36);
                  case 'larger':
                    _fontSize = (_fontSize + 1).clamp(12, 36);
                  case 'narrower':
                    _contentWidth = (_contentWidth - 80).clamp(420, 1200);
                  case 'wider':
                    _contentWidth = (_contentWidth + 80).clamp(420, 1200);
                  case 'line':
                    _lineHeight = _lineHeight >= 1.8 ? 1.3 : _lineHeight + .1;
                  case 'sepia':
                    _sepia = !_sepia;
                }
              }),
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'smaller',
                  child: Text('Schrift kleiner'),
                ),
                const PopupMenuItem(
                  value: 'larger',
                  child: Text('Schrift größer'),
                ),
                const PopupMenuItem(
                  value: 'narrower',
                  child: Text('Text schmaler'),
                ),
                const PopupMenuItem(
                  value: 'wider',
                  child: Text('Text breiter'),
                ),
                const PopupMenuItem(
                  value: 'line',
                  child: Text('Zeilenabstand ändern'),
                ),
                CheckedPopupMenuItem(
                  value: 'sepia',
                  checked: _sepia,
                  child: const Text('Sepia'),
                ),
              ],
            ),
          ],
          bottom: progress == null
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(value: progress),
                ),
        ),
        body: Focus(
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
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  vertical: 36,
                  horizontal: 20,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: _contentWidth),
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
                                  padding: const EdgeInsets.only(bottom: 18),
                                  child: Text(
                                    widget.document.paragraphs[index].text,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: _fontSize,
                                      height: _lineHeight,
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
        bottomNavigationBar:
            !widget.hasPreviousChapter && !widget.hasNextChapter
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
