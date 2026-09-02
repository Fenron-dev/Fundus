import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

final class ZipArchiveEntry {
  const ZipArchiveEntry({
    required this.path,
    required this.archiveName,
    required this.isDirectory,
    required this.size,
  });

  final String path;
  final String archiveName;
  final bool isDirectory;
  final int size;

  String get name => p.posix.basename(path);
  String get parentPath {
    final parent = p.posix.dirname(path);
    return parent == '.' ? '' : parent;
  }
}

final class ZipArchiveSnapshot {
  const ZipArchiveSnapshot({required this.entries});

  final List<ZipArchiveEntry> entries;

  List<ZipArchiveEntry> childrenOf(String parentPath) {
    final result = entries
        .where((entry) => entry.parentPath == parentPath)
        .toList(growable: false);
    result.sort((left, right) {
      if (left.isDirectory != right.isDirectory) {
        return left.isDirectory ? -1 : 1;
      }
      return left.name.toLowerCase().compareTo(right.name.toLowerCase());
    });
    return result;
  }
}

final class ZipArchiveService {
  const ZipArchiveService({
    this.maxArchiveBytes = 1024 * 1024 * 1024,
    this.maxEntries = 10000,
    this.maxEntryBytes = 256 * 1024 * 1024,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxEntryBytes;
  final int maxTotalBytes;

  Future<ZipArchiveSnapshot> inspect(String archivePath) =>
      Isolate.run(() => _inspectSync(archivePath));

  Future<String> extractToTemporaryFile(
    String archivePath,
    ZipArchiveEntry target,
  ) => Isolate.run(() => _extractSync(archivePath, target));

  Future<Map<String, String>> extractToTemporaryFiles(
    String archivePath,
    List<ZipArchiveEntry> targets,
  ) => Isolate.run(() => _extractManySync(archivePath, targets));

  ZipArchiveSnapshot _inspectSync(String archivePath) {
    final archiveFile = File(archivePath);
    if (!archiveFile.existsSync()) {
      throw const ZipArchiveException(
        'Das ZIP-Archiv ist nicht mehr vorhanden.',
      );
    }
    if (archiveFile.lengthSync() > maxArchiveBytes) {
      throw const ZipArchiveException(
        'Das ZIP-Archiv ist zu groß für die Vorschau.',
      );
    }
    final archive = _decode(archivePath);
    try {
      if (archive.length > maxEntries) {
        throw const ZipArchiveException(
          'Das ZIP-Archiv enthält zu viele Einträge.',
        );
      }
      var totalBytes = 0;
      final entries = <String, ZipArchiveEntry>{};
      for (final file in archive) {
        final canonical = _canonicalPath(file.name);
        // macOS stores Finder metadata in AppleDouble sidecar entries. They
        // are not user media and must never become visible archive children
        // (in particular, `._cover.png` must not be treated as a comic page).
        if (isArchiveMetadataPath(canonical)) continue;
        if (file.isSymbolicLink) {
          throw const ZipArchiveException(
            'ZIP-Archive mit symbolischen Verknüpfungen werden nicht geöffnet.',
          );
        }
        if (file.isFile) {
          if (file.size > maxEntryBytes) {
            throw ZipArchiveException(
              'Der Eintrag „${p.posix.basename(canonical)}“ ist zu groß.',
            );
          }
          totalBytes += file.size;
          if (totalBytes > maxTotalBytes) {
            throw const ZipArchiveException(
              'Der entpackte Gesamtinhalt des ZIP-Archivs ist zu groß.',
            );
          }
        }
        _addParentDirectories(entries, canonical);
        entries[canonical] = ZipArchiveEntry(
          path: canonical,
          archiveName: file.name,
          isDirectory: file.isDirectory,
          size: file.isFile ? file.size : 0,
        );
      }
      return ZipArchiveSnapshot(
        entries: List<ZipArchiveEntry>.unmodifiable(entries.values),
      );
    } finally {
      archive.clearSync();
    }
  }

  String _extractSync(String archivePath, ZipArchiveEntry target) {
    final result = _extractManySync(archivePath, [target]);
    return result[target.path]!;
  }

  Map<String, String> _extractManySync(
    String archivePath,
    List<ZipArchiveEntry> targets,
  ) {
    if (targets.isEmpty) return const {};
    final canonicalTargets = <String, ZipArchiveEntry>{};
    for (final target in targets) {
      if (target.isDirectory) {
        throw const ZipArchiveException(
          'Ordner können nicht als Datei geöffnet werden.',
        );
      }
      final canonicalTarget = _canonicalPath(target.archiveName);
      if (canonicalTarget != target.path || target.size > maxEntryBytes) {
        throw const ZipArchiveException(
          'Der ZIP-Eintrag ist nicht mehr gültig.',
        );
      }
      canonicalTargets[target.archiveName] = target;
    }
    final archive = _decode(archivePath);
    Directory? targetDirectory;
    try {
      final previewRoot = Directory(
        p.join(Directory.systemTemp.path, 'fundus-archive-preview'),
      )..createSync(recursive: true);
      _removeStalePreviews(previewRoot);
      targetDirectory = previewRoot.createTempSync('entries-');
      final result = <String, String>{};
      for (final entry in canonicalTargets.entries) {
        final target = entry.value;
        final file = archive.find(entry.key);
        if (file == null || !file.isFile || file.isSymbolicLink) {
          throw const ZipArchiveException(
            'Der ZIP-Eintrag konnte nicht gefunden werden.',
          );
        }
        if (file.size > maxEntryBytes) {
          throw const ZipArchiveException('Der ZIP-Eintrag ist zu groß.');
        }
        final output = File(
          p.join(targetDirectory.path, '${result.length}-${target.name}'),
        );
        final stream = OutputFileStream(output.path);
        try {
          file.writeContent(stream);
        } finally {
          stream.closeSync();
        }
        if (output.lengthSync() > maxEntryBytes) {
          throw const ZipArchiveException(
            'Der ZIP-Eintrag überschreitet beim Entpacken die Größenbegrenzung.',
          );
        }
        result[target.path] = output.path;
      }
      return result;
    } on ZipArchiveException {
      if (targetDirectory?.existsSync() ?? false) {
        targetDirectory!.deleteSync(recursive: true);
      }
      rethrow;
    } catch (_) {
      if (targetDirectory?.existsSync() ?? false) {
        targetDirectory!.deleteSync(recursive: true);
      }
      throw const ZipArchiveException(
        'Der ZIP-Eintrag konnte nicht entpackt werden.',
      );
    } finally {
      archive.clearSync();
    }
  }

  Archive _decode(String archivePath) {
    try {
      return ZipDecoder().decodeStream(InputFileStream(archivePath));
    } catch (_) {
      throw const ZipArchiveException(
        'Das ZIP-Archiv ist beschädigt oder verschlüsselt.',
      );
    }
  }

  static String _canonicalPath(String value) {
    final normalized = value
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized.contains('\u0000')) {
      throw const ZipArchiveException(
        'Das ZIP-Archiv enthält einen unsicheren Pfad.',
      );
    }
    final parts = normalized.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const ZipArchiveException(
        'Das ZIP-Archiv enthält einen unsicheren Pfad.',
      );
    }
    return p.posix.joinAll(parts);
  }

  static void _addParentDirectories(
    Map<String, ZipArchiveEntry> entries,
    String path,
  ) {
    var parent = p.posix.dirname(path);
    while (parent != '.') {
      entries.putIfAbsent(
        parent,
        () => ZipArchiveEntry(
          path: parent,
          archiveName: '$parent/',
          isDirectory: true,
          size: 0,
        ),
      );
      parent = p.posix.dirname(parent);
    }
  }

  static void _removeStalePreviews(Directory root) {
    final oldest = DateTime.now().subtract(const Duration(days: 1));
    for (final entity in root.listSync(followLinks: false)) {
      try {
        if (entity.statSync().modified.isBefore(oldest)) {
          entity.deleteSync(recursive: true);
        }
      } catch (_) {
        // A currently open preview may remain until a later cleanup pass.
      }
    }
  }
}

/// Platform metadata entries commonly introduced when archives are created
/// or copied on macOS. Kept top-level so CBZ page selection can apply the same
/// rule without depending on the archive service implementation.
bool isArchiveMetadataPath(String path) {
  final components = p.posix.split(path);
  return components.any(
    (component) =>
        component == '__MACOSX' ||
        component == '.DS_Store' ||
        component == 'Thumbs.db' ||
        component.startsWith('._'),
  );
}

final class ZipArchiveException implements Exception {
  const ZipArchiveException(this.message);

  final String message;

  @override
  String toString() => message;
}

Future<void> showZipArchiveBrowser(
  BuildContext context, {
  required String archivePath,
  required Future<void> Function(String path) onOpenExtracted,
}) => showDialog<void>(
  context: context,
  builder: (context) => _ZipArchiveBrowserDialog(
    archivePath: archivePath,
    onOpenExtracted: onOpenExtracted,
  ),
);

class _ZipArchiveBrowserDialog extends StatefulWidget {
  const _ZipArchiveBrowserDialog({
    required this.archivePath,
    required this.onOpenExtracted,
  });

  final String archivePath;
  final Future<void> Function(String path) onOpenExtracted;

  @override
  State<_ZipArchiveBrowserDialog> createState() =>
      _ZipArchiveBrowserDialogState();
}

class _ZipArchiveBrowserDialogState extends State<_ZipArchiveBrowserDialog> {
  final _service = const ZipArchiveService();
  late final Future<ZipArchiveSnapshot> _snapshot = _service.inspect(
    widget.archivePath,
  );
  String _currentPath = '';
  bool _opening = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Row(
      children: [
        const Icon(Icons.folder_zip_outlined),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _currentPath.isEmpty
                ? p.basename(widget.archivePath)
                : _currentPath,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
    content: SizedBox(
      width: 680,
      height: 520,
      child: FutureBuilder<ZipArchiveSnapshot>(
        future: _snapshot,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                snapshot.error is ZipArchiveException
                    ? (snapshot.error! as ZipArchiveException).message
                    : 'Das ZIP-Archiv konnte nicht gelesen werden.',
                textAlign: TextAlign.center,
              ),
            );
          }
          final entries = snapshot.data!.childrenOf(_currentPath);
          return Column(
            children: [
              if (_currentPath.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.arrow_upward),
                  title: const Text('Übergeordneter Ordner'),
                  onTap: _opening
                      ? null
                      : () => setState(() {
                          final parent = p.posix.dirname(_currentPath);
                          _currentPath = parent == '.' ? '' : parent;
                        }),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('Dieser Ordner ist leer.'))
                    : ListView.builder(
                        itemCount: entries.length,
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return ListTile(
                            leading: Icon(
                              entry.isDirectory
                                  ? Icons.folder_outlined
                                  : _archiveEntryIcon(entry.name),
                            ),
                            title: Text(entry.name),
                            subtitle: entry.isDirectory
                                ? null
                                : Text(_formatByteSize(entry.size)),
                            trailing: Icon(
                              entry.isDirectory
                                  ? Icons.chevron_right
                                  : Icons.open_in_new,
                            ),
                            onTap: _opening
                                ? null
                                : () => entry.isDirectory
                                      ? setState(
                                          () => _currentPath = entry.path,
                                        )
                                      : _open(entry),
                          );
                        },
                      ),
              ),
              if (_opening) const LinearProgressIndicator(),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: _opening ? null : () => Navigator.pop(context),
        child: const Text('Schließen'),
      ),
    ],
  );

  Future<void> _open(ZipArchiveEntry entry) async {
    setState(() => _opening = true);
    try {
      final path = await _service.extractToTemporaryFile(
        widget.archivePath,
        entry,
      );
      await widget.onOpenExtracted(path);
    } on ZipArchiveException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }
}

IconData _archiveEntryIcon(String filename) =>
    switch (p.extension(filename).toLowerCase()) {
      '.pdf' => Icons.picture_as_pdf_outlined,
      '.jpg' || '.jpeg' || '.png' || '.webp' || '.gif' => Icons.image_outlined,
      '.zip' => Icons.folder_zip_outlined,
      _ => Icons.insert_drive_file_outlined,
    };

String _formatByteSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
