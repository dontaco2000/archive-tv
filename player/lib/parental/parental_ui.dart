import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'parental.dart';
import 'parental_flow.dart';

const _font = 'Consolas';
const _panel = Color(0xF0101A5C);
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);

/// Lock marker shown next to locked channels in the guide.
const lockMarker = '\u{1F512}';

TextStyle _style(double size, Color color, {bool bold = false}) =>
    TextStyle(fontFamily: _font, fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : null);

/// Keys that still reach the TV while a parental screen is up (volume, mute, fullscreen).
final _passThrough = {
  LogicalKeyboardKey.equal,
  LogicalKeyboardKey.minus,
  LogicalKeyboardKey.keyU,
  LogicalKeyboardKey.space,
  LogicalKeyboardKey.mediaPlayPause,
  LogicalKeyboardKey.f11,
};

int? _digitOf(LogicalKeyboardKey k) {
  for (final base in [LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0]) {
    final d = k.keyId - base.keyId;
    if (d >= 0 && d <= 9) return d;
  }
  return null;
}

/// On-screen 4-digit PIN entry. Number keys type (Windows keyboard, remote page); a TV remote without
/// digits picks each one with Up/Down and moves on with Right/OK (Fire TV). Esc/Back cancels.
class PinPrompt extends StatefulWidget {
  final PinRequest request;
  final VoidCallback onCancel;
  const PinPrompt({super.key, required this.request, required this.onCancel});

  @override
  State<PinPrompt> createState() => PinPromptState();
}

class PinPromptState extends State<PinPrompt> {
  final _focus = FocusNode();
  final List<int?> digits = List.filled(4, null);
  int cursor = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _next() {
    digits[cursor] ??= 0;
    if (cursor == 3) {
      widget.request.onPin(digits.join());
    } else {
      setState(() => cursor++);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (_passThrough.contains(k)) return KeyEventResult.ignored;
    final d = _digitOf(k);
    if (d != null) {
      digits[cursor] = d;
      _next();
    } else if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      setState(() => digits[cursor] = ((digits[cursor] ?? 0) + (k == LogicalKeyboardKey.arrowUp ? 1 : -1)) % 10);
    } else if (e is KeyRepeatEvent) {
      // only the digit picker repeats
    } else if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) {
      _next();
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.backspace) {
      setState(() {
        if (k == LogicalKeyboardKey.backspace) digits[cursor] = null;
        if (cursor > 0) cursor--;
      });
    } else if (k == LogicalKeyboardKey.escape) {
      widget.onCancel();
    }
    return KeyEventResult.handled; // nothing else reaches the TV underneath
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.7,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Container(
              color: _panel,
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('$lockMarker ${r.title}', style: _style(30, Colors.white, bold: true)),
                const SizedBox(height: 8),
                Text(r.hint ?? 'Enter the parental PIN', style: _style(22, r.hint?.startsWith('Wrong') == true ? const Color(0xFFFF8A80) : const Color(0xFF9EC8FF))),
                const SizedBox(height: 16),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  for (var i = 0; i < 4; i++)
                    Container(
                      width: 64,
                      height: 80,
                      margin: const EdgeInsets.all(6),
                      alignment: Alignment.center,
                      color: i == cursor ? _yellow : _cellBg,
                      child: Text(
                        i == cursor ? '${digits[i] ?? 0}' : (digits[i] == null ? '_' : '*'),
                        style: _style(44, i == cursor ? Colors.black : Colors.white, bold: true),
                      ),
                    ),
                ]),
                const SizedBox(height: 16),
                Text(
                  Platform.isAndroid ? 'Up/Down: digit   Right/OK: next   Back: cancel' : 'Type 4 digits (or Up/Down, Enter)   Esc: cancel',
                  style: _style(18, const Color(0xFF9EC8FF)),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Menu > Parental controls. Rows depend on the state: no PIN yet / lock ON / lock OFF (only then the
/// channel list can be edited, since turning the lock OFF already took the PIN).
class ParentalOverlay extends StatefulWidget {
  static const selectedKey = ValueKey('parental-selected');

  final Parental parental;
  final List<Channel> channels;
  final ParentalFlow flow;

  /// False while a PIN prompt is up over this screen (it has the keys); true again takes focus back.
  final bool active;
  final VoidCallback onChanged;
  final VoidCallback onClose;

  const ParentalOverlay({
    super.key,
    required this.parental,
    required this.channels,
    required this.flow,
    required this.onChanged,
    required this.onClose,
    this.active = true,
  });

  @override
  State<ParentalOverlay> createState() => _ParentalOverlayState();
}

typedef _Row = (String label, void Function()? action);

/// The rows of the parental screen (label, Enter action; null = information only). Public for tests.
List<(String, void Function()?)> parentalRows(Parental p, List<Channel> channels, ParentalFlow flow, VoidCallback changed, VoidCallback close) {
  if (!p.hasPin) return [('Set PIN', flow.setPin), ('Close', close)];
  return [
    p.lockOn ? ('Parental lock: ON (Enter + PIN: turn OFF)', flow.deactivate) : ('Parental lock: OFF (Enter: turn ON)', flow.activate),
    if (!p.lockOn)
      ('Lock mature channels', () {
        final n = p.lockMature(channels);
        changed();
        flow.flash(n == 0 ? 'Mature channels already locked' : 'Locked $n mature channels');
      }),
    ('Change PIN', flow.changePin),
    ('Remove PIN and parental controls', flow.removePin),
    if (p.lockOn) ('Turn the lock OFF to change the channel list', null),
    if (!p.lockOn)
      for (final c in channels)
        ('${c.number} ${c.name}${c.mature ? ' (mature)' : ''}: ${p.locked.contains(c.number) ? 'LOCKED' : 'open'}', () {
          p.toggle(c.number);
          changed();
        }),
    ('Close', close),
  ];
}

class _ParentalOverlayState extends State<ParentalOverlay> {
  final _focus = FocusNode();
  int _sel = 0, _scroll = 0;
  static const _visible = 13;

  @override
  void initState() {
    super.initState();
    _grabFocus();
  }

  void _grabFocus() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) _focus.requestFocus();
      });

  @override
  void didUpdateWidget(ParentalOverlay old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _grabFocus();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  List<_Row> get _rows => parentalRows(widget.parental, widget.channels, widget.flow, () {
        widget.onChanged();
        if (mounted) setState(() {});
      }, widget.onClose);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final n = _rows.length;
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _sel = (_sel - 1) % n);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + 1) % n);
    } else if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.pageDown) {
      setState(() => _sel = (_sel + (k == LogicalKeyboardKey.pageUp ? -_visible : _visible)).clamp(0, n - 1));
    } else if (e is KeyRepeatEvent) {
      // toggles fire once per press
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      _rows[_sel.clamp(0, n - 1)].$2?.call();
      if (mounted) setState(() {});
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.keyM || k == LogicalKeyboardKey.contextMenu) {
      widget.onClose();
    } else {
      return _passThrough.contains(k) ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    _sel = _sel.clamp(0, rows.length - 1);
    if (_sel < _scroll) _scroll = _sel;
    if (_sel >= _scroll + _visible) _scroll = _sel - _visible + 1;
    _scroll = _scroll.clamp(0, (rows.length - _visible).clamp(0, rows.length));
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: 0.6,
          heightFactor: 0.9,
          child: Container(
            color: _panel,
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, box) {
              final unit = box.maxHeight / (_visible + 3);
              final font = (unit * 0.42).clamp(9.0, 26.0);
              Widget line(String t, Color c, {bool bold = false}) => SizedBox(
                    height: unit,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(t, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: _style(font, c, bold: bold)),
                    ),
                  );
              return Column(children: [
                line('$lockMarker PARENTAL CONTROLS', _yellow, bold: true),
                // The menu text documents the model (user decision 2026-11-12).
                line('Lock ON: locked channels need the PIN.', const Color(0xFF9EC8FF)),
                line('The PIN turns it OFF until turned ON. Family lock only.', const Color(0xFF9EC8FF)),
                for (final (i, r) in rows.indexed.skip(_scroll).take(_visible))
                  Container(
                    key: i == _sel ? ParentalOverlay.selectedKey : null,
                    height: unit - 2,
                    margin: const EdgeInsets.all(1),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.centerLeft,
                    color: i == _sel ? _yellow : (r.$2 == null ? Colors.transparent : _cellBg),
                    child: Text(
                      r.$1,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: _style(font, i == _sel ? Colors.black : Colors.white, bold: i == _sel),
                    ),
                  ),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}
