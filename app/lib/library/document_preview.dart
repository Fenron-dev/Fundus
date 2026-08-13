import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

final class NativePdfRenderer {
  const NativePdfRenderer();

  static const _channel = MethodChannel('dev.fundus/pdf_renderer');

  Future<int> pageCount(String path) async {
    try {
      final count = await _channel.invokeMethod<int>('pageCount', {
        'path': path,
      });
      if (count == null || count < 1) {
        throw const DocumentPreviewException(
          'Die PDF-Datei enthält keine Seiten.',
        );
      }
      return count;
    } on PlatformException catch (error) {
      throw DocumentPreviewException(
        error.message ?? 'Die PDF-Datei konnte nicht gelesen werden.',
      );
    } on MissingPluginException {
      throw const DocumentPreviewException(
        'Die interne PDF-Vorschau ist auf diesem Gerät nicht verfügbar.',
      );
    }
  }

  Future<Uint8List> renderPage(
    String path,
    int page, {
    int maxWidth = 1800,
  }) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('renderPage', {
        'path': path,
        'page': page,
        'maxWidth': maxWidth,
      });
      if (bytes == null || bytes.isEmpty) {
        throw const DocumentPreviewException(
          'Die PDF-Seite konnte nicht dargestellt werden.',
        );
      }
      return bytes;
    } on PlatformException catch (error) {
      throw DocumentPreviewException(
        error.message ?? 'Die PDF-Seite konnte nicht dargestellt werden.',
      );
    } on MissingPluginException {
      throw const DocumentPreviewException(
        'Die interne PDF-Vorschau ist auf diesem Gerät nicht verfügbar.',
      );
    }
  }
}

final class DocumentPreviewException implements Exception {
  const DocumentPreviewException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool supportsInternalDocumentPreview(String path) => const {
  '.pdf',
  '.jpg',
  '.jpeg',
  '.png',
  '.webp',
  '.gif',
  '.bmp',
}.contains(p.extension(path).toLowerCase());

Future<void> showDocumentPreview(
  BuildContext context, {
  required String path,
  required Future<void> Function(String path) onOpenExternal,
}) async {
  if (!await File(path).exists()) {
    throw const DocumentPreviewException(
      'Die Datei ist nicht mehr am gespeicherten Ort vorhanden.',
    );
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _DocumentPreviewDialog(path: path, onOpenExternal: onOpenExternal),
  );
}

class _DocumentPreviewDialog extends StatefulWidget {
  const _DocumentPreviewDialog({
    required this.path,
    required this.onOpenExternal,
  });

  final String path;
  final Future<void> Function(String path) onOpenExternal;

  @override
  State<_DocumentPreviewDialog> createState() => _DocumentPreviewDialogState();
}

class _DocumentPreviewDialogState extends State<_DocumentPreviewDialog> {
  final _pdf = const NativePdfRenderer();
  final _pages = PageController();
  final Map<int, Future<Uint8List>> _renderedPages = {};
  Future<int>? _pageCount;
  int _currentPage = 0;

  bool get _isPdf => p.extension(widget.path).toLowerCase() == '.pdf';

  @override
  void initState() {
    super.initState();
    if (_isPdf) _pageCount = _pdf.pageCount(widget.path);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            tooltip: 'Vorschau schließen',
            icon: const Icon(Icons.close),
          ),
          title: Text(p.basename(widget.path), overflow: TextOverflow.ellipsis),
          actions: [
            TextButton.icon(
              onPressed: () => widget.onOpenExternal(widget.path),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Extern öffnen'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: _isPdf
              ? _pdfBody(size.width)
              : _zoomableImage(
                  Image.file(
                    File(widget.path),
                    cacheWidth: (size.width * 2).clamp(1200, 3200).round(),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => _PreviewError(
                      message: 'Das Bild konnte nicht dargestellt werden.',
                      onExternal: () => widget.onOpenExternal(widget.path),
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Widget _pdfBody(double width) => FutureBuilder<int>(
    future: _pageCount,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.hasError) {
        return _PreviewError(
          message: snapshot.error is DocumentPreviewException
              ? (snapshot.error! as DocumentPreviewException).message
              : 'Die PDF-Datei konnte nicht gelesen werden.',
          onExternal: () => widget.onOpenExternal(widget.path),
        );
      }
      final pageCount = snapshot.data!;
      return Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pages,
              itemCount: pageCount,
              onPageChanged: (page) {
                setState(() {
                  _currentPage = page;
                  _renderedPages.removeWhere(
                    (renderedPage, _) => (renderedPage - page).abs() > 2,
                  );
                });
              },
              itemBuilder: (context, page) => FutureBuilder<Uint8List>(
                future: _renderedPages.putIfAbsent(
                  page,
                  () => _pdf.renderPage(
                    widget.path,
                    page,
                    maxWidth: width.clamp(900, 2200).round(),
                  ),
                ),
                builder: (context, pageSnapshot) {
                  if (pageSnapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (pageSnapshot.hasError) {
                    return Center(
                      child: Text(
                        pageSnapshot.error is DocumentPreviewException
                            ? (pageSnapshot.error! as DocumentPreviewException)
                                  .message
                            : 'Seite ${page + 1} konnte nicht dargestellt werden.',
                      ),
                    );
                  }
                  return _zoomableImage(
                    Image.memory(pageSnapshot.data!, fit: BoxFit.contain),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _currentPage == 0
                        ? null
                        : () => _pages.previousPage(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                          ),
                    tooltip: 'Vorherige Seite',
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('Seite ${_currentPage + 1} von $pageCount'),
                  IconButton(
                    onPressed: _currentPage + 1 >= pageCount
                        ? null
                        : () => _pages.nextPage(
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
  );

  Widget _zoomableImage(Widget image) =>
      InteractiveViewer(minScale: .5, maxScale: 6, child: Center(child: image));
}

class _PreviewError extends StatelessWidget {
  const _PreviewError({required this.message, required this.onExternal});

  final String message;
  final VoidCallback onExternal;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: onExternal,
            icon: const Icon(Icons.open_in_new),
            label: const Text('Extern öffnen'),
          ),
        ],
      ),
    ),
  );
}
