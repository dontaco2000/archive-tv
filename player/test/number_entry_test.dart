import 'package:archive_tv_core/archive_tv_core.dart';
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
    expect(keyboardBindings[LogicalKeyboardKey.keyF]!.action, TvAction.favorite);
  });

  test('flipTarget honours favorites only, falling back to all channels', () {
    final chs = [for (final n in [2, 3, 5, 8]) Channel(number: n, name: 'C$n')];
    int? flip(int? cur, int step, Set<int> favs, bool only) =>
        flipTarget(chs, cur, step, favorites: favs, favoritesOnly: only)?.number;
    expect(flip(2, 1, {3, 8}, false), 3); // off: every channel
    expect(flip(3, 1, {3, 8}, true), 8); // skips 5
    expect(flip(8, 1, {3, 8}, true), 3); // wraps
    expect(flip(3, -1, {3, 8}, true), 8);
    expect(flip(5, 1, {3, 8}, true), 3); // from a non-favorite
    expect(flip(2, 1, {}, true), 3); // no favorites: all channels
    expect(flip(2, 1, {99}, true), 3); // favorite not tunable: all channels
    expect(flipTarget(const [], 2, 1), isNull);
  });
}
