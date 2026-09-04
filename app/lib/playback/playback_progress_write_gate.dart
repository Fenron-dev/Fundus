/// Prevents identical playback progress snapshots from being written more
/// than once. Player lifecycle events can arrive in quick succession (for
/// example pause followed by close), especially when a vault is on a network
/// volume. A changed track, position or duration remains an explicit write.
final class PlaybackProgressWriteGate {
  String? _workId;
  String? _fileId;
  Duration? _position;
  Duration? _duration;
  bool _finished = false;

  bool shouldWrite({
    required String workId,
    required String fileId,
    required Duration position,
    Duration? duration,
    bool finished = false,
  }) {
    final snapshotChanged =
        _workId != workId ||
        _fileId != fileId ||
        _position != position ||
        _duration != duration;
    if (snapshotChanged) return true;
    // A completion is a state transition, not a reason to write the same
    // snapshot on every `completed`, pause and close callback. Once the
    // finished state was persisted, an identical non-finished lifecycle event
    // must not regress it or create another network write.
    if (finished) return !_finished;
    return false;
  }

  void markSaved({
    required String workId,
    required String fileId,
    required Duration position,
    Duration? duration,
    bool finished = false,
  }) {
    _workId = workId;
    _fileId = fileId;
    _position = position;
    _duration = duration;
    _finished = finished;
  }
}
