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

/// Phones and tablets: the screen stays on while Archive TV is in front (a TV never sleeps on its own).
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
  final rw = max(w - h * aspect, 260.0); // 260 dp: the remote at about 90% of its drawn size
  return (fit(w - rw, h, 0), Rect.fromLTWH(w - rw, 0, rw, h));
}

/// The phone/tablet screen: the TV [frame] (laid out at [frameHeight] high and scaled, so the banner, STAND BY card
/// and warnings look like on the TV), the [remote] in the space left, and an open [panel] (guide, menu, PIN...)
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
          Positioned.fromRect(
            key: videoKey,
            rect: v,
            child: FittedBox(child: SizedBox(width: frameHeight * aspect, height: frameHeight, child: frame)),
          ),
          if (r != null)
            Positioned.fromRect(
              key: remoteKey,
              rect: r,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: FittedBox(child: SizedBox.fromSize(size: TouchRemote.size, child: remote)),
              ),
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

const _font = 'Consolas';
const _yellow = Color(0xFFFFEB3B);
const _blue = Color(0xFF1E2C8A);

const _icons = {
  '▲': Icons.arrow_drop_up,
  '▼': Icons.arrow_drop_down,
  '◀': Icons.arrow_left,
  '▶': Icons.arrow_right,
  '★': Icons.star,
  '⌫': Icons.backspace_outlined,
};

/// A big rounded button that never takes keyboard focus (the TV screen keeps the keys).
class TouchButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color, text;
  const TouchButton(this.label, this.onTap, {super.key, this.color = _blue, this.text = Colors.white});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(3),
        child: Material(
          type: MaterialType.button,
          color: color,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  // Symbol words are drawn as Material icons: phone fonts may lack the arrow / star glyphs.
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    for (final (i, w) in label.split(' ').indexed) ...[
                      if (i > 0) const SizedBox(width: 4),
                      if (_icons[w] case final icon?)
                        Icon(icon, color: text, size: 24)
                      else
                        Text(w, style: TextStyle(fontFamily: _font, fontSize: 18, fontWeight: FontWeight.bold, color: text)),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Under an open panel: Back and the D-pad, so every overlay works by touch the way it works on a TV remote.
class TouchBar extends StatelessWidget {
  final void Function(LogicalKeyboardKey) press;
  const TouchBar({super.key, required this.press});

  @override
  Widget build(BuildContext context) => Container(
        height: 56,
        color: const Color(0xFF060A2A),
        child: Row(children: [
          for (final (label, key) in [
            ('BACK', LogicalKeyboardKey.escape),
            ('◀', LogicalKeyboardKey.arrowLeft),
            ('▲', LogicalKeyboardKey.arrowUp),
            ('▼', LogicalKeyboardKey.arrowDown),
            ('▶', LogicalKeyboardKey.arrowRight),
            ('OK', LogicalKeyboardKey.enter),
          ])
            Expanded(child: TouchButton(label, () => press(key))),
        ]),
      );
}

/// The on-screen remote: a Flutter version of the Windows remote page (remote_page.dart), drawn at [size] and
/// scaled to its space. [state] is the same map the remote page reads (TvScreen._remoteState).
class TouchRemote extends StatefulWidget {
  static const size = Size(300, 460);

  final Map<String, Object?> state;
  final Channel? channel;
  final void Function(LogicalKeyboardKey) press;
  final void Function(int) setVolume;
  final VoidCallback onPower, onFullscreen;

  const TouchRemote({
    super.key,
    required this.state,
    this.channel,
    required this.press,
    required this.setVolume,
    required this.onPower,
    required this.onFullscreen,
  });

  @override
  State<TouchRemote> createState() => _TouchRemoteState();
}

class _TouchRemoteState extends State<TouchRemote> {
  bool _numbers = false;
  double? _drag; // the volume slider while a finger is on it

  void _k(String name) => widget.press(remoteKeys[name]!);

  Widget _b(String label, String key, {Color color = _blue, Color text = Colors.white}) => TouchButton(label, () => _k(key), color: color, text: text);

  Widget _row(double h, List<Widget> children) => SizedBox(height: h, child: Row(children: [for (final c in children) Expanded(child: c)]));

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final ch = s['channel'] as Map?;
    final muted = s['muted'] == true;
    final volume = (s['volume'] as int? ?? 0).toDouble();
    TextStyle style(double size, Color c, {bool bold = false}) =>
        TextStyle(fontFamily: _font, fontSize: size, color: c, fontWeight: bold ? FontWeight.bold : null);
    final info = [
      if (s['minutesLeft'] case final int m) '$m min left',
      if (s['onDemand'] == true) 'ON DEMAND',
      if (s['favorite'] == true) '★ FAV',
      if (s['sleep'] case final int m) 'SLEEP $m',
      if (s['rated'] == true) 'R',
    ].join('  ');
    return Column(children: [
      SizedBox(
        height: 44,
        child: Row(children: [
          SizedBox(width: 100, child: TouchButton('POWER', widget.onPower, color: const Color(0xFFB71C1C))),
          const Spacer(),
          SizedBox(
            width: 110,
            child: _b(muted ? 'MUTED' : 'MUTE', 'mute', color: muted ? const Color(0xFFFFB300) : const Color(0xFF37474F), text: muted ? Colors.black : Colors.white),
          ),
        ]),
      ),
      // The "LCD": channel, programme, minutes left.
      Container(
        height: 76,
        margin: const EdgeInsets.all(3),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: const Color(0xFF0A0A3A), borderRadius: BorderRadius.circular(8), border: Border.all(color: _blue, width: 2)),
        child: Row(children: [
          if (widget.channel != null) SizedBox(width: 64, child: ChannelLogo(channel: widget.channel!, height: 44)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(ch == null ? '-- ----' : '${ch['number']}  ${'${ch['name']}'.toUpperCase()}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: style(16, Colors.white, bold: true)),
              Text('${s['title'] ?? s['message'] ?? (s['standBy'] == true ? 'STAND BY' : '')}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: style(13, const Color(0xFFFFE08A))),
              Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: style(12, const Color(0xFF9EC8FF))),
            ]),
          ),
        ]),
      ),
      _row(44, [
        _b('GUIDE', 'guide', color: const Color(0xFFC62828)),
        _b('MENU', 'menu', color: const Color(0xFF2E7D32)),
        _b('INFO', 'info', color: const Color(0xFF1565C0)),
        _b('ON DEM', 'ondemand', color: const Color(0xFFF9A825), text: Colors.black),
      ]),
      SizedBox(height: 196, child: _numbers ? _numpad() : _dpad()),
      SizedBox(
        height: 44,
        child: Row(children: [
          SizedBox(width: 52, child: _b('−', 'volDown')),
          Expanded(
            child: Slider(
              value: (_drag ?? volume).clamp(0, 100),
              max: 100,
              activeColor: _yellow,
              inactiveColor: _blue,
              onChanged: (v) => setState(() => _drag = v),
              onChangeEnd: (v) {
                widget.setVolume(v.round());
                setState(() => _drag = null);
              },
            ),
          ),
          SizedBox(width: 30, child: Text('${(_drag ?? volume).round()}', textAlign: TextAlign.center, style: style(14, Colors.white, bold: true))),
          SizedBox(width: 52, child: _b('+', 'volUp')),
        ]),
      ),
      _row(44, [
        TouchButton(_numbers ? 'PAD' : '123', () => setState(() => _numbers = !_numbers)),
        _b('LAST', 'last'),
        _b('SLEEP', 'sleep'),
        TouchButton('PIC', () => widget.press(LogicalKeyboardKey.keyP)),
        TouchButton('FULL', widget.onFullscreen),
      ]),
    ]);
  }

  /// Back/Fav, the D-pad with OK, CH up/down.
  Widget _dpad() {
    const none = SizedBox.shrink();
    Widget col(List<Widget> c) => Column(children: [for (final w in c) Expanded(child: w)]);
    return Row(children: [
      SizedBox(width: 70, child: col([_b('BACK', 'back'), _b('★ FAV', 'favorite')])),
      Expanded(
        child: col([
          Row(children: [const Expanded(child: none), Expanded(child: _b('▲', 'up')), const Expanded(child: none)]),
          Row(children: [
            Expanded(child: _b('◀', 'left')),
            Expanded(child: _b('OK', 'ok', color: _yellow, text: Colors.black)),
            Expanded(child: _b('▶', 'right')),
          ]),
          Row(children: [const Expanded(child: none), Expanded(child: _b('▼', 'down')), const Expanded(child: none)]),
        ]),
      ),
      SizedBox(width: 70, child: col([_b('CH ▲', 'channelUp'), _b('CH ▼', 'channelDown')])),
    ]);
  }

  /// Channel number pad: digits as typed on a TV remote (the TV commits after a pause, or on GO).
  Widget _numpad() => Column(children: [
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
                  child: k == 'close'
                      ? TouchButton('CLOSE', () => setState(() => _numbers = false), color: const Color(0xFF37474F))
                      : _b(k == 'ok' ? 'GO' : k, k, color: k == 'ok' ? _yellow : _blue, text: k == 'ok' ? Colors.black : Colors.white),
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
        width: 270,
        height: 280,
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
                      -2 => TouchButton('CANCEL', onCancel, color: const Color(0xFF37474F)),
                      -1 => TouchButton('⌫', onErase, color: const Color(0xFF37474F)),
                      _ => TouchButton('$d', () => onDigit(d)),
                    },
                  ),
              ]),
            ),
        ]),
      );
}
