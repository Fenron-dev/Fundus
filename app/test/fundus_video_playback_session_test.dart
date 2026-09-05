import 'package:flutter_test/flutter_test.dart';

import 'package:fundus/playback/fundus_video_playback_session.dart';

void main() {
  test('aligned resume positions do not require a second native seek', () {
    expect(
      FundusVideoPlaybackSession.isResumePositionAligned(
        const Duration(seconds: 120),
        const Duration(seconds: 121),
      ),
      isTrue,
    );
    expect(
      FundusVideoPlaybackSession.isResumePositionAligned(
        const Duration(seconds: 120),
        const Duration(seconds: 124),
      ),
      isFalse,
    );
  });

  test('a new title at zero is already aligned', () {
    expect(
      FundusVideoPlaybackSession.isResumePositionAligned(
        Duration.zero,
        Duration.zero,
      ),
      isTrue,
    );
  });
}
