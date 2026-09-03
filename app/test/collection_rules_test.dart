import 'package:flutter_test/flutter_test.dart';
import 'package:fundus_core/fundus_core.dart';

import 'package:fundus/library/collection_rules.dart';

LibraryWorkSummary _work({
  String kind = 'tv',
  String? style,
  String? sensitivity,
  List<String> tags = const ['Star Wars', 'Sci-Fi'],
}) => LibraryWorkSummary(
  id: 'work-1',
  kind: kind,
  title: 'A New Hope',
  author: 'George Lucas',
  fileCount: 1,
  addedAt: DateTime(2026),
  contentStyle: style,
  contentSensitivity: sensitivity,
  tags: tags,
);

void main() {
  test('smart rules match provider-neutral metadata', () {
    expect(
      matchesCollectionRules(_work(style: 'anime'), {
        'kinds': ['tv'],
        'content_styles': ['anime'],
        'tags_all': ['star wars'],
      }),
      isTrue,
    );
    expect(
      matchesCollectionRules(_work(style: 'anime'), {
        'content_styles': ['documentary'],
      }),
      isFalse,
    );
  });

  test('rules can be generated from active query and section', () {
    final rules = collectionRulesFromQuery(
      const LibraryWorkQuery(
        text: 'space',
        tags: {'Sci-Fi'},
        offlineOnly: true,
      ),
      sectionKinds: {'movie', 'tv'},
      contentStyle: 'anime',
    );
    expect(rules['kinds'], containsAll(['movie', 'tv']));
    expect(rules['content_styles'], ['anime']);
    expect(rules['text'], 'space');
    expect(rules['offline_only'], isTrue);
    expect(rules['tags_all'], ['Sci-Fi']);
  });
}
