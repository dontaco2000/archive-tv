import 'dart:io';
import 'dart:math';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../remote/remote_server.dart' show remoteKeys;
import 'channel_logo.dart';

// Phone / tablet touch UI (queue item 31). TV devices (Fire TV, Android TV, no touchscreen) and Windows keep the
// D-pad/keyboard UI untouched. Every touch button presses the same key the keyboard, Fire TV remote and the Windows
// remote page press (remoteKeys), so all behaviour stays in TvScreen and the overlays' key handlers.

enum DeviceKind { tv, tablet, phone }

/// [tv]: the platform said TV (or it is a desktop). Touch devices with a shortest side of 600 dp or more are tablets.
DeviceKind deviceKind({required bool tv, required Size size}) =>
    tv ? DeviceKind.tv : (size.shortestSide >= 600 ? DeviceKind.tablet : DeviceKind.phone);

const _device = MethodChannel('archivetv/device');

/// Android: MainActivity.kt says TV for UiModeManager TELEVISION, the leanback or Fire TV feature, or no
/// touchscreen. Other platforms (Windows) and a failed check: true, i.e. today's UI.
Future<bool> isTvDevice() async {
  if (!Platform.isAndroid) return true;
  try {
    return await _device.invokeMethod<bool>('isTv') ?? true;
  } on Object {
    return true;
  }
}

/// The screen stays on while Archive TV is in front (phones, tablets and Fire TV, whose screensaver would otherwise blank the picture).
Future<void> keepScreenOn() async {
  try {
    await _device.invokeMethod<void>('keepScreenOn');
  } on Object {
    // not fatal
  }
}

/// Marks the overlays under it as touch overlays: full-screen panels, tappable rows, scrolling by drag.
class TouchUi extends InheritedWidget {
  const TouchUi({super.key, required super.child});

  static bool of(BuildContext c) => c.dependOnInheritedWidgetOfExactType<TouchUi>() != null;

  @override
  bool updateShouldNotify(TouchUi old) => false;
}

/// Where the video ([aspect] wide per 1 high) and the remote go on a [screen]. Portrait: video the full width at
/// the top (at most 55% of the height), remote below. Landscape: the biggest video that leaves the remote at
/// least 260 dp on the right. [full]: the video alone, as big as fits; no remote.
(Rect video, Rect? remote) touchSplit(Size screen, double aspect, {bool full = false}) {
  final w = screen.width, h = screen.height;
  Rect fit(double bw, double bh, double left) {
    final vw = min(bw, bh * aspect), vh = vw / aspect;
    return Rect.fromLTWH(left + (bw - vw) / 2, (bh - vh) / 2, vw, vh);
  }

  if (full) return (fit(w, h, 0), null);
  if (h >= w) {
    final vh = min(w / aspect, h * 0.55), vw = vh * aspect;
    return (Rect.fromLTWH((w - vw) / 2, 0, vw, vh), Rect.fromLTRB(0, vh, w, h));
  }
  final rw = max(w - h * aspect, 260.0); // the largest 4:3 box that leaves the remote at least 260 dp
  return (fit(w - rw, h, 0), Rect.fromLTWH(w - rw, 0, rw, h));
}

/// The phone/tablet screen: the TV [frame] (laid out at [frameHeight] high and scaled, so the banner, STAND BY card
/// and warnings look like on the TV), the [remote] filling the space left, and an open [panel] (guide, menu, PIN...)
/// over everything with a Back / arrows / OK bar under it.
class TouchLayout extends StatelessWidget {
  static const frameHeight = 480.0;
  static const remoteKey = ValueKey('touch-remote');
  static const videoKey = ValueKey('touch-video');

  final double aspect;
  final bool full;
  final Widget frame, remote;
  final Widget? panel;
  final void Function(LogicalKeyboardKey) press;

  const TouchLayout({super.key, required this.aspect, required this.full, required this.frame, required this.remote, this.panel, required this.press});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final (v, r) = touchSplit(box.biggest, aspect, full: full);
        return Stack(children: [
          if (r != null) Positioned.fromRect(key: remoteKey, rect: r, child: remote),
          Positioned.fromRect(
            key: videoKey,
            rect: v,
            child: FittedBox(child: SizedBox(width: frameHeight * aspect, height: frameHeight, child: frame)),
          ),
          if (panel != null)
            Positioned.fill(
              child: Column(children: [
                // Dark and hit-opaque: the remote underneath can't be pressed through a panel's margins.
                Expanded(child: ColoredBox(color: const Color(0xCC000000), child: TouchUi(child: panel!))),
                TouchBar(press: press),
              ]),
            ),
        ]);
      });
}

// ---- The Windows remote page's keys and layout (remote_page.dart: raised keys, green LCD, round D-pad) in the app's
// guide/menu navy with yellow accents.
const _font = 'Consolas';
const _mono = ['monospace']; // phones have no Consolas
const _txt = Color(0xFFE8E6DF);
const _dim = Color(0xFF8D8B99);
const _btn = Color(0xFF26306E); // navy keys on the guide/menu blue (0xFF101A5C)
const _btnDown = Color(0xFF3A4590);
const _yellow = Color(0xFFFFEB3B);
const _amber = Color(0xFFFFC24A);
const _lcdTxt = Color(0xFF8DFFB0);
const _red = Color(0xFF5A2523), _green = Color(0xFF244D33), _blueKey = Color(0xFF253A63), _yellowKey = Color(0xFF5B4F1F);

const _icons = {
  '▲': Icons.arrow_drop_up,
  '▼': Icons.arrow_drop_down,
  '◀': Icons.arrow_left,
  '▶': Icons.arrow_right,
  '★': Icons.star,
  '⌫': Icons.backspace_outlined,
  'POWER': Icons.power_settings_new,
};

/// A raised remote key (as on the Windows remote): sinks 2 px while pressed, never takes keyboard focus
/// (the TV screen keeps the keys). [size] is the text size; symbol words draw as Material icons, since phone
/// fonts may lack the arrow / star glyphs.
class TouchButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final Color color, text;
  final double size;
  final double radius;
  const TouchButton(this.label, this.onTap, {super.key, this.color = _btn, this.text = _txt, this.size = 16, this.radius = 10});

  @override
  State<TouchButton> createState() => _TouchButtonState();
}

class _TouchButtonState extends State<TouchButton> {
  bool _down = false;

  void _set(bool d) {
    if (mounted && d != _down) setState(() => _down = d);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final r = BorderRadius.circular(w.radius);
    return Padding(
      padding: const EdgeInsets.all(3),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _set(true),
        onTapUp: (_) => _set(false),
        onTapCancel: () => _set(false),
        onTap: () {
          HapticFeedback.selectionClick();
          w.onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          transform: Matrix4.translationValues(0, _down ? 2 : 0, 0),
          decoration: BoxDecoration(
            borderRadius: r,
            color: _down ? Color.lerp(w.color, _btnDown, 0.6) : w.color,
            gradient: _down
                ? null
                : LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(w.color, Colors.white, 0.08)!, w.color]),
            boxShadow: _down ? null : const [BoxShadow(color: Color(0xFF0B0B0E), offset: Offset(0, 2))],
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                for (final (i, word) in w.label.split(' ').indexed) ...[
                  if (i > 0) SizedBox(width: w.size * 0.25),
                  if (_icons[word] case final icon?)
                    Icon(icon, color: w.text, size: w.size * 1.5)
                  else
                    Text(word, style: TextStyle(fontSize: w.size, fontWeight: FontWeight.w600, letterSpacing: 0.5, color: w.text)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Under an open panel: Back and the D-pad, so every overlay works by touch the way it works on a TV remote.
class TouchBar extends StatelessWidget {
  final void Function(LogicalKeyboardKey) press;
  const TouchBar({super.key, required this.press});

  @override
  Widget build(BuildContext context) => Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        color: const Color(0xFF0A1142),
        child: Row(children: [
          for (final (label, key) in [
            ('BACK', LogicalKeyboardKey.escape),
            ('◀', LogicalKeyboardKey.arrowLeft),
            ('▲', LogicalKeyboardKey.arrowUp),
            ('▼', LogicalKeyboardKey.arrowDown),
            ('▶', LogicalKeyboardKey.arrowRight),
            ('OK', LogicalKeyboardKey.enter),
          ])
            Expanded(child: TouchButton(label, () => press(key), size: 17)),
        ]),
      );
}

/// The on-screen remote: a native port of the Windows remote page (remote_page.dart) with the same keys in the same
/// places. It fills whatever box it gets: rows share the height, so taller screens get bigger keys, not gaps.
/// [state] is the map the remote page reads (TvScreen._remoteState).
class TouchRemote extends StatefulWidget {
  final Map<String, Object?> state;
  final Channel? channel;
  final void Function(LogicalKeyboardKey) press;
  final void Function(int) setVolume;
  final VoidCallback onPower, onFullscreen;

  /// The first POWER tap armed it: the key shows TAP AGAIN (TvScreen turns off on the second within 3 s).
  final bool powerArmed;

  const TouchRemote({
    super.key,
    required this.state,
    this.channel,
    required this.press,
    required this.setVolume,
    required this.onPower,
    required this.onFullscreen,
    this.powerArmed = false,
  });

  @override
  State<TouchRemote> createState() => _TouchRemoteState();
}

class _TouchRemoteState extends State<TouchRemote> {
  bool _numbers = false;
  double? _drag; // the volume bar while a finger is on it

  void _k(String name) => widget.press(remoteKeys[name]!);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        // Row heights in "units": top 0.8, LCD 1.5, pills 0.9, middle 3.9, volume 0.9, bottom 0.9 (+ gaps).
        // A box over twice as tall as wide (tablet landscape side column) stacks instead: pills 2 x 2, the D-pad
        // alone at full width, then BACK / FAV / CH up / CH down in one row.
        final tall = box.maxHeight > box.maxWidth * 2;
        final unit = (box.maxHeight - 16) / (tall ? 11.6 : 9.6);
        final w = min(box.maxWidth, box.maxHeight * 1.4); // only a very wide, short box keeps side margins
        final fs = (unit * 0.3).clamp(11.0, 26.0); // key text
        final s = widget.state;
        final muted = s['muted'] == true;
        Widget b(String label, String key, {Color color = _btn, Color text = _txt, double r = 10}) =>
            TouchButton(label, () => _k(key), color: color, text: text, size: fs, radius: r);
        Widget row(double h, List<Widget> children) => SizedBox(height: h, child: Row(children: [for (final c in children) Expanded(child: c)]));

        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF1B2675), Color(0xFF101A5C), Color(0xFF0A1142)], stops: [0, 0.55, 1]),
          ),
          child: Center(
            child: SizedBox(
              width: w,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Column(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  // POWER (two taps) left, MUTE right, as on the Windows remote.
                  SizedBox(
                    height: unit * 0.8,
                    child: Row(children: [
                      SizedBox(
                        width: min(widget.powerArmed ? unit * 3.2 : unit * 1.4, (w - 12) * (widget.powerArmed ? 0.55 : 0.3)),
                        child: TouchButton(widget.powerArmed ? 'POWER TAP AGAIN' : 'POWER', widget.onPower,
                            color: widget.powerArmed ? const Color(0xFFFF3B30) : const Color(0xFFB3261E), text: Colors.white, size: fs * 0.9, radius: unit),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: min(unit * 2.2, (w - 12) * 0.4),
                        child: b(muted ? 'MUTED' : 'MUTE', 'mute', color: muted ? const Color(0xFF7A2A26) : _btn, text: muted ? Colors.white : _txt, r: unit),
                      ),
                    ]),
                  ),
                  SizedBox(height: unit * 1.5, child: _lcd(unit)),
                  if (tall) ...[
                    row(unit * 0.9, [b('GUIDE', 'guide', color: _red, r: unit), b('MENU', 'menu', color: _green, r: unit)]),
                    row(unit * 0.9, [b('INFO', 'info', color: _blueKey, r: unit), b('ON DEM', 'ondemand', color: _yellowKey, r: unit)]),
                  ] else
                    row(unit * 0.9, [
                      b('GUIDE', 'guide', color: _red, r: unit),
                      b('MENU', 'menu', color: _green, r: unit),
                      b('INFO', 'info', color: _blueKey, r: unit),
                      b('ON DEM', 'ondemand', color: _yellowKey, r: unit),
                    ]),
                  SizedBox(height: unit * 3.9, child: _numbers ? _numpad(fs) : _middle(unit, fs, sides: !tall)),
                  if (tall)
                    row(unit * 0.9, [
                      b('BACK', 'back'),
                      b('★ FAV', 'favorite', text: s['favorite'] == true ? _amber : _txt),
                      b('CH ▲', 'channelUp'),
                      b('CH ▼', 'channelDown'),
                    ]),
                  SizedBox(height: unit * 0.9, child: _volume(unit, fs)),
                  row(unit * 0.9, [
                    TouchButton(_numbers ? 'PAD' : '123', () => setState(() => _numbers = !_numbers), size: fs, color: _numbers ? _btnDown : _btn),
                    b('LAST', 'last'),
                    b('SLEEP', 'sleep', text: s['sleep'] != null ? _amber : _txt),
                    TouchButton('PIC', () => widget.press(LogicalKeyboardKey.keyP), size: fs),
                    TouchButton('FULL', widget.onFullscreen, size: fs),
                  ]),
                ]),
              ),
            ),
          ),
        );
      });

  /// Now playing: logo, channel, programme, minutes left / typed number, the open screen; ARCHIVE TV in the corner.
  Widget _lcd(double unit) {
    final s = widget.state;
    final ch = s['channel'] as Map?;
    final f = (unit * 0.27).clamp(9.0, 22.0); // three lines in 1.5 units
    TextStyle mono(double size, Color c, {bool bold = false}) =>
        TextStyle(fontFamily: _font, fontFamilyFallback: _mono, fontSize: size, color: c, fontWeight: bold ? FontWeight.bold : null, shadows: const [Shadow(color: Color(0x554DFF8A), blurRadius: 6)]);
    final entry = s['entry'] as String? ?? '';
    final minutes = s['minutesLeft'];
    final left = entry.isNotEmpty
        ? 'CH ${entry}_'
        : s['onDemand'] == true
            ? 'ON DEMAND'
            : minutes is int
                ? '$minutes min left'
                : '';
    final mode = s['mode'] is String && s['mode'] != 'watch' ? (s['mode'] as String).toUpperCase() : '';
    return Container(
      margin: const EdgeInsets.all(3),
      padding: EdgeInsets.symmetric(horizontal: unit * 0.15, vertical: unit * 0.08),
      decoration: BoxDecoration(
        color: const Color(0xFF0D1A12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.black),
        gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF050B07), Color(0xFF0D1A12)], stops: [0, 0.25]),
      ),
      child: Stack(children: [
        Positioned(right: 0, top: 0, child: Text('ARCHIVE TV', style: TextStyle(fontFamily: _font, fontFamilyFallback: _mono, fontSize: f * 0.55, fontWeight: FontWeight.bold, letterSpacing: 2, color: const Color(0xFF4A7A5A)))),
        Row(children: [
          if (widget.channel != null)
            Container(
              width: unit * 1.3,
              height: unit * 1.0,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(color: const Color(0x10FFFFFF), borderRadius: BorderRadius.circular(4)),
              child: ChannelLogo(channel: widget.channel!, height: unit),
            ),
          SizedBox(width: unit * 0.15),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(ch == null ? '-- ----' : '${ch['number']} ${'${ch['name']}'.toUpperCase()}', maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(f * 1.1, _lcdTxt, bold: true)),
              Text('${s['title'] ?? s['message'] ?? (s['standBy'] == true ? 'STAND BY' : '')}'.replaceAll('\n', ' '),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(f * 0.9, const Color(0xFFD9FFE4))),
              Row(children: [
                Expanded(child: Text(left, maxLines: 1, style: mono(f * 0.8, const Color(0xFF6FCF8F)))),
                if (s['rated'] == true) Text('R  ', style: mono(f * 0.8, _amber, bold: true)),
                Text(mode, style: mono(f * 0.8, _amber)),
              ]),
            ]),
          ),
        ]),
      ]),
    );
  }

  /// BACK / FAV | round D-pad with OK | CH up / CH down, as on the Windows remote.
  /// [sides] false: the D-pad alone (the side keys are a row of their own).
  Widget _middle(double unit, double fs, {bool sides = true}) {
    final fav = widget.state['favorite'] == true;
    return LayoutBuilder(builder: (context, box) {
      final d = min(box.maxHeight, box.maxWidth * (sides ? 0.58 : 1)); // the D-pad disk
      final c = (d - 16) / 3; // one D-pad cell
      // The side keys share the column's height: no dead gap between BACK and FAV, CH up and down.
      Widget side(List<Widget> keys) => Expanded(child: Column(children: [for (final k in keys) Expanded(child: k)]));
      Widget cell(int col, int row, Widget child) => Positioned(left: 8 + col * c, top: 8 + row * c, width: c, height: c, child: child);
      return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (sides) side([
          TouchButton('BACK', () => _k('back'), size: fs),
          TouchButton('★ FAV', () => _k('favorite'), size: fs, text: fav ? _amber : _txt),
        ]),
        Container(
          width: d,
          height: d,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(colors: [Color(0xFF2E3A88), Color(0xFF141D5A)]),
            boxShadow: [BoxShadow(color: Color(0xAA000000), blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: Stack(children: [
            cell(1, 0, TouchButton('▲', () => _k('up'), size: fs * 1.6)),
            cell(0, 1, TouchButton('◀', () => _k('left'), size: fs * 1.6)),
            cell(1, 1, TouchButton('OK', () => _k('ok'), size: fs * 1.1, color: _yellow, text: Colors.black, radius: c)),
            cell(2, 1, TouchButton('▶', () => _k('right'), size: fs * 1.6)),
            cell(1, 2, TouchButton('▼', () => _k('down'), size: fs * 1.6)),
          ]),
        ),
        if (sides) side([
          TouchButton('CH ▲', () => _k('channelUp'), size: fs),
          TouchButton('CH ▼', () => _k('channelDown'), size: fs),
        ]),
      ]);
    });
  }

  /// − [green level bar: tap or drag] +
  Widget _volume(double unit, double fs) {
    final s = widget.state;
    final muted = s['muted'] == true;
    final level = (_drag ?? (s['volume'] as int? ?? 0).toDouble()).clamp(0.0, 100.0);
    return Row(children: [
      SizedBox(width: min(unit * 1.2, 72), child: TouchButton('−', () => _k('volDown'), size: fs * 1.2)),
      Expanded(
        child: LayoutBuilder(builder: (context, box) {
          double at(Offset p) => (p.dx / box.maxWidth * 100).clamp(0.0, 100.0);
          void end() {
            if (_drag != null) widget.setVolume(_drag!.round());
            setState(() => _drag = null);
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => setState(() => _drag = at(d.localPosition)),
            onTapUp: (_) => end(),
            onHorizontalDragUpdate: (d) => setState(() => _drag = at(d.localPosition)),
            onHorizontalDragEnd: (_) => end(),
            child: Center(
              child: Container(
                height: unit * 0.5,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF04100A),
                  borderRadius: BorderRadius.circular(unit * 0.25),
                  border: Border.all(color: const Color(0xFF2A5A3A)),
                ),
                child: Stack(fit: StackFit.expand, children: [
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: level / 100,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: muted ? null : const LinearGradient(colors: [Color(0xFF2F9B55), _lcdTxt]),
                        color: muted ? const Color(0xFF5A3A3A) : null,
                      ),
                    ),
                  ),
                  Center(
                    child: Text(muted ? 'MUTED' : '${level.round()}',
                        style: TextStyle(fontFamily: _font, fontFamilyFallback: _mono, fontSize: unit * 0.3, fontWeight: FontWeight.bold, color: Colors.white, shadows: const [Shadow(blurRadius: 3)])),
                  ),
                ]),
              ),
            ),
          );
        }),
      ),
      SizedBox(width: min(unit * 1.2, 72), child: TouchButton('+', () => _k('volUp'), size: fs * 1.2)),
    ]);
  }

  /// CHANNEL # pad in the D-pad's place: digits as typed on a TV remote (the TV commits after a pause, or on GO).
  Widget _numpad(double fs) => Column(children: [
        for (final r in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['close', '0', 'ok'],
        ])
          Expanded(
            child: Row(children: [
              for (final k in r)
                Expanded(
                  child: switch (k) {
                    'close' => TouchButton('CLOSE', () => setState(() => _numbers = false), size: fs * 0.9, text: _dim),
                    'ok' => TouchButton('GO', () => _k('ok'), size: fs, color: _green),
                    _ => TouchButton(k, () => _k(k), size: fs * 1.3),
                  },
                ),
            ]),
          ),
      ]);
}

/// A 3 x 4 digit pad for the parental PIN on touch screens: [onDigit] 0-9, [onErase], [onCancel].
class PinPad extends StatelessWidget {
  final void Function(int) onDigit;
  final VoidCallback onErase, onCancel;
  const PinPad({super.key, required this.onDigit, required this.onErase, required this.onCancel});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        height: 300,
        child: Column(children: [
          for (final r in const [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9],
            [-2, 0, -1],
          ])
            Expanded(
              child: Row(children: [
                for (final d in r)
                  Expanded(
                    child: switch (d) {
                      -2 => TouchButton('CANCEL', onCancel, size: 16, text: _dim),
                      -1 => TouchButton('⌫', onErase, size: 18),
                      _ => TouchButton('$d', () => onDigit(d), size: 26),
                    },
                  ),
              ]),
            ),
        ]),
      );
}
