import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('writes and reads portable default media roots', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-config-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/config.yaml');
    final configuration = LibraryConfiguration();

    await configuration.write(file);
    final restored = await LibraryConfiguration.readOrDefault(file);

    expect(
      restored.rootsFor('audiobook'),
      containsAll(['Audiobooks', 'Hörbücher']),
    );
    expect(restored.rootsFor('podcast'), ['Podcasts']);
    expect(restored.rootsFor('image'), contains('Pictures'));
    expect(restored.rootsFor('webnovel'), contains('Webnovels'));
    expect(restored.rootsFor('manga'), containsAll(['Manga', 'Comics']));
  });

  test('custom roots override one kind and retain other defaults', () async {
    final directory = await Directory.systemTemp.createTemp('fundus-config-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/config.yaml');
    await file.writeAsString('''
media_roots:
  audiobook:
    - Medien/Audio
''');

    final configuration = await LibraryConfiguration.readOrDefault(file);

    expect(configuration.rootsFor('audiobook'), ['Medien/Audio']);
    expect(configuration.rootsFor('podcast'), ['Podcasts']);
  });
}
