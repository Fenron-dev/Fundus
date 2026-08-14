import 'dart:io';

import 'package:flutter/material.dart';
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

Future<void> showComicBookViewer(
  BuildContext context, {
  required String archivePath,
  int initialPage = 0,
  void Function(int page, int total)? onPageChanged,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _ComicBookDialog(
    archivePath: archivePath,
    initialPage: initialPage,
    onPageChanged: onPageChanged,
  ),
);

class _ComicBookDialog extends StatefulWidget {
  const _ComicBookDialog({
    required this.archivePath,
    required this.initialPage,
    required this.onPageChanged,
  });

  final String archivePath;
  final int initialPage;
  final void Function(int page, int total)? onPageChanged;

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
  int _currentPage = 0;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          tooltip: 'Comic schließen',
          icon: const Icon(Icons.close),
        ),
        title: Text(
          p.basenameWithoutExtension(widget.archivePath),
          overflow: TextOverflow.ellipsis,
        ),
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
          final initial = widget.initialPage.clamp(0, pages.length - 1);
          _controller ??= PageController(initialPage: initial);
          if (_currentPage == 0 && initial > 0) _currentPage = initial;
          return Column(
            children: [
              Expanded(
                child: ColoredBox(
                  color: Colors.black,
                  child: PageView.builder(
                    controller: _controller,
                    itemCount: pages.length,
                    onPageChanged: (page) {
                      setState(() {
                        _currentPage = page;
                        _extractedPages.removeWhere(
                          (cached, _) => (cached - page).abs() > 2,
                        );
                      });
                      widget.onPageChanged?.call(page, pages.length);
                    },
                    itemBuilder: (context, page) => FutureBuilder<String>(
                      future: _extractedPages.putIfAbsent(
                        page,
                        () => _service.extractToTemporaryFile(
                          widget.archivePath,
                          pages[page],
                        ),
                      ),
                      builder: (context, pageSnapshot) {
                        if (pageSnapshot.connectionState !=
                            ConnectionState.done) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        if (pageSnapshot.hasError) {
                          return Center(
                            child: Text(
                              'Seite ${page + 1} konnte nicht geöffnet werden.',
                              style: const TextStyle(color: Colors.white),
                            ),
                          );
                        }
                        return InteractiveViewer(
                          minScale: .5,
                          maxScale: 6,
                          child: Center(
                            child: Image.file(
                              File(pageSnapshot.data!),
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) => Text(
                                'Seite ${page + 1} konnte nicht dargestellt werden.',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
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
                        onPressed: _currentPage == 0
                            ? null
                            : () => _controller!.previousPage(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                              ),
                        tooltip: 'Vorherige Seite',
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('Seite ${_currentPage + 1} von ${pages.length}'),
                      IconButton(
                        onPressed: _currentPage + 1 >= pages.length
                            ? null
                            : () => _controller!.nextPage(
                                duration: const Duration(milliseconds: 180),
                                curve: Curves.easeOut,
                              ),
                        tooltip: 'Nächste Seite',
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

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
