import 'package:archive_tv_player/input/gamepad.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('XInput button changes become key presses and releases', () {
    const a = 0x1000, up = 0x0001, rb = 0x0200;
    expect(buttonChanges(0, a), [(LogicalKeyboardKey.enter, true)]);
    expect(buttonChanges(a, a | rb), [(LogicalKeyboardKey.pageUp, true)]);
    expect(buttonChanges(a | up, 0).toSet(), {(LogicalKeyboardKey.arrowUp, false), (LogicalKeyboardKey.enter, false)});
    expect(buttonChanges(a, a), isEmpty);
  });

  test('the left stick acts as the D-pad past the dead zone', () {
    expect(withStick(0, 0, 30000), 0x0001); // up
    expect(withStick(0, -30000, 0), 0x0004); // left
    expect(withStick(0x1000, 5000, -5000), 0x1000); // inside the dead zone
  });

  testWidgets('Android pad buttons reach the screens as Enter / Esc / guide / menu / channel keys', (tester) async {
    final got = <LogicalKeyboardKey>[];
    await tester.pumpWidget(MaterialApp(
      home: Focus(
        autofocus: true,
        onKeyEvent: (_, e) {
          // The raw button event follows the translated one; screens ignore it (TvScreen swallows it).
          if (e is KeyDownEvent && !gamepadKeys.containsKey(e.logicalKey)) got.add(e.logicalKey);
          return KeyEventResult.handled;
        },
        child: const SizedBox(),
      ),
    ));
    installGamepad(pollXInput: false);
    for (final k in [
      LogicalKeyboardKey.gameButtonA,
      LogicalKeyboardKey.gameButtonB,
      LogicalKeyboardKey.gameButtonX,
      LogicalKeyboardKey.gameButtonY,
      LogicalKeyboardKey.gameButtonStart,
      LogicalKeyboardKey.gameButtonLeft1,
      LogicalKeyboardKey.gameButtonRight1,
      LogicalKeyboardKey.arrowUp, // D-pad arrives as arrows already
    ]) {
      await tester.sendKeyEvent(k);
    }
    expect(got, [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.escape,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.arrowUp,
    ]);
  });
}
