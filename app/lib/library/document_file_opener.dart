import 'dart:io';

import 'package:flutter/services.dart';

final class DocumentFileOpener {
  const DocumentFileOpener();

  static const _channel = MethodChannel('dev.fundus/file_opener');

  Future<void> open(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const DocumentOpenException(
        'Die Datei ist nicht mehr am gespeicherten Ort vorhanden.',
      );
    }
    if (!Platform.isAndroid && !Platform.isMacOS) {
      throw const DocumentOpenException(
        'Das Öffnen von Dokumenten wird auf diesem System noch nicht unterstützt.',
      );
    }
    try {
      final opened = await _channel.invokeMethod<bool>('open', {'path': path});
      if (opened != true) {
        throw const DocumentOpenException(
          'Für diesen Dateityp wurde keine passende App gefunden.',
        );
      }
    } on PlatformException catch (error) {
      throw DocumentOpenException(
        error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : 'Die Datei konnte nicht geöffnet werden.',
      );
    } on MissingPluginException {
      throw const DocumentOpenException(
        'Diese App-Version unterstützt das Öffnen von Dokumenten noch nicht.',
      );
    }
  }
}

final class DocumentOpenException implements Exception {
  const DocumentOpenException(this.message);

  final String message;

  @override
  String toString() => message;
}
