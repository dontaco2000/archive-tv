import 'dart:ui';

import 'package:archive_tv_player/settings/window_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const screen = Rect.fromLTWH(0, 0, 1920, 1040);

  test('a window already on screen is left alone', () {
    const r = Rect.fromLTWH(100, 50, 960, 720);
    expect(clampToScreen(r, screen), r);
  });

  test('a window hanging off the edge is pulled back on', () {
    expect(clampToScreen(const Rect.fromLTWH(1500, 900, 960, 720), screen), const Rect.fromLTWH(960, 320, 960, 720));
    expect(clampToScreen(const Rect.fromLTWH(-300, -20, 960, 720), screen), const Rect.fromLTWH(0, 0, 960, 720));
  });

  test('a window bigger than the screen shrinks and keeps 4:3', () {
    final r = clampToScreen(const Rect.fromLTWH(0, 0, 2000, 1500), screen);
    expect(r.height, 1040);
    expect(r.width / r.height, closeTo(4 / 3, 1e-9));
    expect(screen.contains(r.topLeft) && r.right <= screen.right && r.bottom <= screen.bottom, isTrue);
  });

  test('works on a display left of the primary (negative coordinates)', () {
    const left = Rect.fromLTWH(-1920, 0, 1920, 1040);
    expect(clampToScreen(const Rect.fromLTWH(-100, 10, 960, 720), left), const Rect.fromLTWH(-960, 10, 960, 720));
  });

  test('frameAspect fills areas within 1.5% of 4:3, else stays 4:3', () {
    expect(frameAspect(944, 708), closeTo(4 / 3, 1e-9));
    expect(frameAspect(944, 700), 944 / 700); // 1.1% off: fill
    expect(frameAspect(1920, 1080), 4 / 3); // fullscreen 16:9 keeps the pillarbox
    expect(frameAspect(960, 689), 4 / 3); // 3% off: 4:3 with bars
  });
}
