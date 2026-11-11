import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive_tv_player/input/actions.dart';

void main() {
  test('digits build a channel number and commit clears it', () {
    final e = NumberEntry()
      ..add(3)
      ..add(3);
    expect(e.text, '33');
    expect(e.commit(), 33);
    expect(e.text, '');
    expect(e.commit(), isNull);
  });

  test('only the last three digits are kept', () {
    final e = NumberEntry();
    for (final d in [1, 2, 3, 4]) {
      e.add(d);
    }
    expect(e.commit(), 234);
  });

  test('keyboard table maps channel, digit and fullscreen keys', () {
    expect(keyboardBindings[LogicalKeyboardKey.pageUp]!.action, TvAction.channelUp);
    expect(keyboardBindings[LogicalKeyboardKey.arrowDown]!.action, TvAction.channelDown);
    expect(keyboardBindings[LogicalKeyboardKey.f11]!.action, TvAction.toggleFullscreen);
    final seven = keyboardBindings[LogicalKeyboardKey.digit7]!;
    expect(seven.action, TvAction.digit);
    expect(seven.digit, 7);
    expect({for (final b in keyboardBindings.values) if (b.action == TvAction.digit) b.digit}, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9});
  });
}
