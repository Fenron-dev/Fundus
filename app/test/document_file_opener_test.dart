import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/document_file_opener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fundus/file_opener');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('passes an existing document to the native file opener', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-open-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/Regelwerk.pdf');
    await file.writeAsBytes([1, 2, 3]);
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return true;
        });

    await const DocumentFileOpener().open(file.path);

    expect(received?.method, 'open');
    expect(received?.arguments, {'path': file.path});
  });

  test('reports a missing document without invoking the platform', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked = true;
          return true;
        });

    await expectLater(
      const DocumentFileOpener().open('/fundus/nicht-vorhanden.pdf'),
      throwsA(
        isA<DocumentOpenException>().having(
          (error) => error.message,
          'message',
          contains('nicht mehr'),
        ),
      ),
    );
    expect(invoked, isFalse);
  });
}
