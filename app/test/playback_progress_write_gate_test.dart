import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/playback_progress_write_gate.dart';

void main() {
  test('suppresses an identical progress snapshot', () {
    final gate = PlaybackProgressWriteGate();
    const position = Duration(seconds: 12);
    const duration = Duration(minutes: 20);

    expect(
      gate.shouldWrite(
        workId: 'work-1',
        fileId: 'episode-1',
        position: position,
        duration: duration,
      ),
      isTrue,
    );
    gate.markSaved(
      workId: 'work-1',
      fileId: 'episode-1',
      position: position,
      duration: duration,
    );
    expect(
      gate.shouldWrite(
        workId: 'work-1',
        fileId: 'episode-1',
        position: position,
        duration: duration,
      ),
      isFalse,
    );
  });

  test('allows changed positions and tracks', () {
    final gate = PlaybackProgressWriteGate();
    gate.markSaved(
      workId: 'work-1',
      fileId: 'episode-1',
      position: const Duration(seconds: 12),
      duration: const Duration(minutes: 20),
    );

    expect(
      gate.shouldWrite(
        workId: 'work-1',
        fileId: 'episode-1',
        position: const Duration(seconds: 13),
        duration: const Duration(minutes: 20),
      ),
      isTrue,
    );
    expect(
      gate.shouldWrite(
        workId: 'work-1',
        fileId: 'episode-2',
        position: const Duration(seconds: 12),
        duration: const Duration(minutes: 20),
      ),
      isTrue,
    );
  });

  test('finished snapshots are always written', () {
    final gate = PlaybackProgressWriteGate();
    const position = Duration(seconds: 12);
    gate.markSaved(workId: 'work-1', fileId: 'episode-1', position: position);

    expect(
      gate.shouldWrite(
        workId: 'work-1',
        fileId: 'episode-1',
        position: position,
        finished: true,
      ),
      isTrue,
    );
    gate.markSaved(
      workId: 'work-1',
      fileId: 'episode-1',
      position: position,
      finished: true,
    );
    expect(
      gate.shouldWrite(
        workId: 'work-1',
        fileId: 'episode-1',
        position: position,
      ),
      isFalse,
    );
  });
}
