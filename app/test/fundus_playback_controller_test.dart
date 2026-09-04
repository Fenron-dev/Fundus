import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/playback/fundus_playback_controller.dart';

/// Keeps the contract test transport-neutral. Concrete media-kit controllers
/// can therefore adopt the interface without opening a native player in the
/// unit-test process.
final class _FakePlaybackController implements FundusPlaybackController {
  @override
  void addListener(void Function() listener) {}

  @override
  void removeListener(void Function() listener) {}

  @override
  String? playbackWorkId = 'work-1';

  @override
  String? playbackWorkTitle = 'Beispiel';

  @override
  String? playbackKind = 'video';

  @override
  String? playbackTrackId = 'file-1';

  @override
  String? playbackTrackTitle = 'Folge 1';

  @override
  int currentIndex = 0;

  @override
  int trackCount = 1;

  @override
  Duration position = Duration.zero;

  @override
  Duration duration = const Duration(minutes: 20);

  @override
  bool playing = false;

  @override
  bool loading = false;

  @override
  String? error;

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> persist({bool finished = false}) async {}

  @override
  Future<void> seek(Duration position) async {
    this.position = position;
  }

  @override
  Future<void> next() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> close() async {}
}

void main() {
  test('common playback contract exposes neutral work and position state', () {
    final controller = _FakePlaybackController();
    expect(controller.playbackWorkId, 'work-1');
    expect(controller.playbackTrackTitle, 'Folge 1');
    expect(controller.trackCount, 1);
    expect(controller.duration, const Duration(minutes: 20));
  });
}
