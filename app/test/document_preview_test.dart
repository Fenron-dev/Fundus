import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/document_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fundus/pdf_renderer');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'native PDF renderer requests page count and one bounded page',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'pageCount') return 12;
            return Uint8List.fromList([1, 2, 3]);
          });
      const renderer = NativePdfRenderer();

      expect(await renderer.pageCount('/library/book.pdf'), 12);
      expect(
        await renderer.renderPage('/library/book.pdf', 2, maxWidth: 1400),
        [1, 2, 3],
      );
      expect(calls.map((call) => call.method), ['pageCount', 'renderPage']);
      expect(calls.last.arguments, {
        'path': '/library/book.pdf',
        'page': 2,
        'maxWidth': 1400,
      });
    },
  );

  test('preview support only includes PDF and Flutter raster formats', () {
    expect(supportsInternalDocumentPreview('/library/book.pdf'), isTrue);
    expect(supportsInternalDocumentPreview('/library/map.PNG'), isTrue);
    expect(supportsInternalDocumentPreview('/library/book.epub'), isFalse);
    expect(supportsInternalDocumentPreview('/library/vector.svg'), isFalse);
  });
}
