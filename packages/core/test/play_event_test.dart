import 'dart:io';

import 'package:fundus_core/fundus_core.dart';
import 'package:test/test.dart';

void main() {
  test('records and closes device-local playback history', () async {
    final root = await Directory.systemTemp.createTemp('fundus-play-events-');
    addTearDown(() => root.delete(recursive: true));
    final workDirectory = Directory('${root.path}/Books/Example');
    await workDirectory.create(recursive: true);
    await File('${workDirectory.path}/example.pdf').writeAsBytes([1, 2, 3]);

    final library = await FundusLibrary.create(root);
    await library.index().drain<void>();
    final work = library.listWorks().single;
    final started = DateTime.utc(2026, 1, 1, 10);
    final event = library.startPlayEvent(
      workId: work.id,
      deviceId: 'tablet',
      startedAt: started,
    );
    expect(event.isOpen, isTrue);
    final history = library.listPlayEvents(work.id);
    expect(history, hasLength(1));
    expect(history.single.id, event.id);
    expect(history.single.startedAt, started);

    final ended = library.finishPlayEvent(
      eventId: event.id,
      secondsPlayed: 42,
      endedAt: started.add(const Duration(minutes: 2)),
    );
    expect(ended.isOpen, isFalse);
    expect(ended.secondsPlayed, 42);
    final completed = library.listPlayEvents(work.id).single;
    expect(completed.id, ended.id);
    expect(completed.secondsPlayed, 42);
    expect(completed.endedAt, ended.endedAt);
  });

  test('does not guess invalid or unknown history updates', () async {
    final database = FundusDatabase.inMemory();
    addTearDown(database.close);
    expect(
      () => database.startPlayEvent(workId: '', deviceId: 'tablet'),
      throwsArgumentError,
    );
    expect(
      () => database.finishPlayEvent(eventId: 'missing', secondsPlayed: 1),
      throwsStateError,
    );
    expect(
      () => database.listPlayEvents('', limit: 0),
      throwsArgumentError,
    );
  });
}
