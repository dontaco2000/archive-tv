import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// Game controllers become the keyboard keys the app already understands, so every screen
// (guide, menu, On Demand, search) works with a pad and no screen needs to know about pads.
// Mapping (spec 5.5): D-pad/left stick = arrows, A = Enter, B = Esc, X = info, Y = guide,
// Start = menu, Back/Select = fullscreen, LB/RB = channel down/up.

/// Android delivers pad buttons as key events; these become the matching keyboard keys.
final Map<LogicalKeyboardKey, LogicalKeyboardKey> gamepadKeys = {
  LogicalKeyboardKey.gameButtonA: LogicalKeyboardKey.enter,
  LogicalKeyboardKey.gameButtonB: LogicalKeyboardKey.escape,
  LogicalKeyboardKey.gameButtonX: LogicalKeyboardKey.keyI,
  LogicalKeyboardKey.gameButtonY: LogicalKeyboardKey.keyG,
  LogicalKeyboardKey.gameButtonStart: LogicalKeyboardKey.keyM,
  LogicalKeyboardKey.gameButtonSelect: LogicalKeyboardKey.f11,
  LogicalKeyboardKey.gameButtonLeft1: LogicalKeyboardKey.pageDown,
  LogicalKeyboardKey.gameButtonRight1: LogicalKeyboardKey.pageUp,
};

/// XInput button bits (wButtons) to keys.
const Map<int, LogicalKeyboardKey> xinputKeys = {
  0x0001: LogicalKeyboardKey.arrowUp,
  0x0002: LogicalKeyboardKey.arrowDown,
  0x0004: LogicalKeyboardKey.arrowLeft,
  0x0008: LogicalKeyboardKey.arrowRight,
  0x0010: LogicalKeyboardKey.keyM, // Start
  0x0020: LogicalKeyboardKey.f11, // Back
  0x0100: LogicalKeyboardKey.pageDown, // LB
  0x0200: LogicalKeyboardKey.pageUp, // RB
  0x1000: LogicalKeyboardKey.enter, // A
  0x2000: LogicalKeyboardKey.escape, // B
  0x4000: LogicalKeyboardKey.keyI, // X
  0x8000: LogicalKeyboardKey.keyG, // Y
};

/// Button bits with the left stick folded in as D-pad bits (past [deadzone]).
int withStick(int buttons, int lx, int ly, {int deadzone = 16000}) {
  var b = buttons;
  if (ly > deadzone) b |= 0x0001;
  if (ly < -deadzone) b |= 0x0002;
  if (lx < -deadzone) b |= 0x0004;
  if (lx > deadzone) b |= 0x0008;
  return b;
}

/// Keys pressed (true) and released (false) between two button states.
List<(LogicalKeyboardKey, bool)> buttonChanges(int before, int now) => [
      for (final MapEntry(key: bit, value: key) in xinputKeys.entries)
        if ((before & bit) != (now & bit)) (key, (now & bit) != 0),
    ];

KeyEvent _event(LogicalKeyboardKey k, {required bool down, bool repeat = false}) {
  final physical = PhysicalKeyboardKey(k.keyId);
  if (repeat) return KeyRepeatEvent(physicalKey: physical, logicalKey: k, timeStamp: Duration.zero);
  return down
      ? KeyDownEvent(physicalKey: physical, logicalKey: k, timeStamp: Duration.zero)
      : KeyUpEvent(physicalKey: physical, logicalKey: k, timeStamp: Duration.zero);
}

/// Delivers [e] the way a real key press would be: to the focused widget, then up its parents,
/// until one handles it.
bool dispatchKey(KeyEvent e) {
  for (FocusNode? n = FocusManager.instance.primaryFocus; n != null; n = n.parent) {
    final r = n.onKeyEvent?.call(n, e);
    if (r == KeyEventResult.handled) return true;
    if (r == KeyEventResult.skipRemainingHandlers) return false;
  }
  return false;
}

/// Hooks controllers into the app's key handling. Call once after runApp. Android pad buttons are
/// re-sent as their keyboard keys (the original button event still arrives after; TvScreen swallows
/// it so Android never turns an unhandled B into Back). On Windows it also polls XInput
/// (no plugin: xinput1_4.dll through dart:ffi).
void installGamepad({void Function(String)? log, bool? pollXInput}) {
  HardwareKeyboard.instance.addHandler((e) {
    final k = gamepadKeys[e.logicalKey];
    if (k != null) dispatchKey(_event(k, down: e is! KeyUpEvent, repeat: e is KeyRepeatEvent));
    return false;
  });
  if (pollXInput ?? Platform.isWindows) _XInput.start((k, {required bool down, bool repeat = false}) => dispatchKey(_event(k, down: down, repeat: repeat)), log);
}

typedef _Send = void Function(LogicalKeyboardKey k, {required bool down, bool repeat});
typedef _GetStateC = Uint32 Function(Uint32, Pointer<Uint8>);
typedef _GetState = int Function(int, Pointer<Uint8>);

/// Polls the first connected XInput pad at 60 Hz (looks for one once a second when none is),
/// turning button changes into key events; held arrows repeat like a keyboard.
class _XInput {
  static void start(_Send send, void Function(String)? log) {
    final _GetState get;
    try {
      final dll = () {
        try {
          return DynamicLibrary.open('xinput1_4.dll');
        } on ArgumentError {
          return DynamicLibrary.open('xinput9_1_0.dll');
        }
      }();
      get = dll.lookupFunction<_GetStateC, _GetState>('XInputGetState');
    } on Object catch (e) {
      log?.call('gamepad: XInput not available ($e)');
      return;
    }
    final state = calloc<Uint8>(16); // XINPUT_STATE: packet(4) buttons(2) triggers(2) lx ly rx ry (2 each)
    final data = state.asTypedList(16).buffer.asByteData();
    int? pad;
    var last = 0;
    var heldSince = DateTime(0);
    var lastRepeat = DateTime(0);
    var idle = 0;

    Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (pad == null) {
        if (idle++ % 60 != 0) return; // probing absent pads is slow-ish: once a second
        for (var i = 0; i < 4; i++) {
          if (get(i, state) == 0) {
            pad = i;
            log?.call('gamepad: controller $i connected');
            break;
          }
        }
        if (pad == null) return;
      }
      if (get(pad!, state) != 0) {
        log?.call('gamepad: controller $pad disconnected');
        for (final (k, _) in buttonChanges(last, 0)) {
          send(k, down: false);
        }
        pad = null;
        last = 0;
        return;
      }
      final now = withStick(data.getUint16(4, Endian.little), data.getInt16(8, Endian.little), data.getInt16(10, Endian.little));
      final t = DateTime.now();
      for (final (k, down) in buttonChanges(last, now)) {
        send(k, down: down);
        if (down) heldSince = t;
      }
      // Held direction: repeat after 400 ms, every 120 ms (channel flip, guide scroll, letters).
      final dirs = now & 0x000F;
      if (dirs != 0 && dirs == (last & 0x000F) && t.difference(heldSince).inMilliseconds > 400 && t.difference(lastRepeat).inMilliseconds > 120) {
        lastRepeat = t;
        for (final MapEntry(key: bit, value: k) in xinputKeys.entries) {
          if (bit <= 0x0008 && (dirs & bit) != 0) send(k, down: true, repeat: true);
        }
      }
      last = now;
    });
  }
}
