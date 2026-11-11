import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// High-score style text entry for a D-pad: a row of slots, up/down cycles the letter
/// under the cursor (blank, A-Z, 0-9), left/right moves between slots. Keyboards may type too.
class ArcadeEntry {
  static const chars = ' ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final List<int> _slots;
  int cursor = 0;

  ArcadeEntry(int length) : _slots = List.filled(length, 0);

  int get length => _slots.length;
  String charAt(int i) => chars[_slots[i]];

  /// The entered text, trailing blanks dropped.
  String get text => _slots.map((i) => chars[i]).join().trimRight();

  void up() => _slots[cursor] = (_slots[cursor] + 1) % chars.length;
  void down() => _slots[cursor] = (_slots[cursor] - 1) % chars.length;
  void left() => cursor = (cursor - 1).clamp(0, length - 1);
  void right() => cursor = (cursor + 1).clamp(0, length - 1);

  void type(String c) {
    final i = chars.indexOf(c.toUpperCase());
    if (c.length != 1 || i < 0) return;
    _slots[cursor] = i;
    right();
  }

  void backspace() {
    if (_slots[cursor] == 0) left();
    _slots[cursor] = 0;
  }

  /// The letter or digit a key types (or space), from its character or, failing that, its key label.
  static String? _typed(KeyEvent e) {
    for (final c in [e.character, e.logicalKey.keyLabel]) {
      if (c != null && c.length == 1 && chars.contains(c.toUpperCase())) return c;
    }
    return null;
  }

  /// Applies an arrow, letter/digit or Backspace key; false if the key is not for the entry.
  bool handleKey(KeyEvent e) {
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp) {
      up();
    } else if (k == LogicalKeyboardKey.arrowDown) {
      down();
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      left();
    } else if (k == LogicalKeyboardKey.arrowRight) {
      right();
    } else if (k == LogicalKeyboardKey.backspace) {
      backspace();
    } else if (_typed(e) case final c?) {
      type(c);
    } else {
      return false;
    }
    return true;
  }
}

/// Draws an [ArcadeEntry]: one box per slot, the cursor slot in yellow ([active] false dims it).
class ArcadeEntryView extends StatelessWidget {
  final ArcadeEntry entry;
  final bool active;
  final double size;
  const ArcadeEntryView({super.key, required this.entry, this.active = true, this.size = 28});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < entry.length; i++)
          Container(
            width: size * 0.9,
            height: size * 1.3,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active && i == entry.cursor ? const Color(0xFFFFEB3B) : const Color(0xFF1E2C8A),
              border: const Border(bottom: BorderSide(color: Colors.white, width: 2)),
            ),
            child: Text(entry.charAt(i),
                style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: size,
                    fontWeight: FontWeight.bold,
                    color: active && i == entry.cursor ? Colors.black : Colors.white)),
          ),
      ]);
}

/// A full-frame prompt around an [ArcadeEntry]: Enter calls [onDone] with the text, Esc [onCancel].
class ArcadePrompt extends StatefulWidget {
  final String title, hint;
  final int length;
  final void Function(String) onDone;
  final VoidCallback onCancel;
  const ArcadePrompt({super.key, required this.title, required this.hint, this.length = 16, required this.onDone, required this.onCancel});

  @override
  State<ArcadePrompt> createState() => _ArcadePromptState();
}

class _ArcadePromptState extends State<ArcadePrompt> {
  final _focus = FocusNode();
  late final _entry = ArcadeEntry(widget.length);

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

  KeyEventResult _onKey(FocusNode n, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) && e is! KeyRepeatEvent) {
      widget.onDone(_entry.text.trim());
    } else if (k == LogicalKeyboardKey.escape && e is! KeyRepeatEvent) {
      widget.onCancel();
    } else if (_entry.handleKey(e)) {
      setState(() {});
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontFamily: 'Consolas', fontSize: 22, color: Color(0xFF9EC8FF));
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Container(
        color: const Color(0xF0101A5C),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.title,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 32, color: Color(0xFFFFEB3B), fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            ArcadeEntryView(entry: _entry),
            const SizedBox(height: 24),
            Text(widget.hint, style: style, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}
