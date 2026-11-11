import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/settings_store.dart';

const _font = 'Consolas';
const _panel = Color(0xE6101A5C); // same dark translucent blue as the guide
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);

enum _Item { favorite, favoritesOnly, volume, mute, startFullscreen, cornerBug, block, refresh, close }

/// Settings menu over the right half of the frame. Changes are made on [settings] in place
/// and reported through [onChanged]; the screen saves and applies them.
class MenuOverlay extends StatefulWidget {
  static const selectedKey = ValueKey('menu-selected');

  final Settings settings;
  final Channel? current;
  final void Function(Settings) onChanged;
  final VoidCallback onBlockCurrent;
  final VoidCallback onRefresh;
  final VoidCallback onClose;

  const MenuOverlay({
    super.key,
    required this.settings,
    required this.current,
    required this.onChanged,
    required this.onBlockCurrent,
    required this.onRefresh,
    required this.onClose,
  });

  @override
  State<MenuOverlay> createState() => _MenuOverlayState();
}

class _MenuOverlayState extends State<MenuOverlay> {
  final _focus = FocusNode();
  int _sel = 0;
  Settings get s => widget.settings;

  @override
  void initState() {
    super.initState();
    // autofocus is ignored when the TV screen already holds focus, so take it explicitly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _change(void Function() f) {
    setState(f);
    widget.onChanged(s);
  }

  /// Left/Right (dir -1/+1) or Enter (dir 0) on the selected item.
  void _activate(int dir) {
    final item = _Item.values[_sel];
    switch (item) {
      case _Item.volume:
        if (dir != 0) _change(() => s.volume = (s.volume + 5 * dir).clamp(0, 100).toDouble());
      case _Item.favorite:
        final c = widget.current;
        if (c != null) _change(() => toggleFavorite(s, c.number));
      case _Item.favoritesOnly:
        _change(() => s.favoritesOnly = !s.favoritesOnly);
      case _Item.mute:
        _change(() => s.muted = !s.muted);
      case _Item.startFullscreen:
        _change(() => s.startFullscreen = !s.startFullscreen);
      case _Item.cornerBug:
        _change(() => s.cornerBug = !s.cornerBug);
      case _Item.block:
        if (dir == 0) widget.onBlockCurrent();
      case _Item.refresh:
        if (dir == 0) widget.onRefresh();
      case _Item.close:
        if (dir == 0) widget.onClose();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    final n = _Item.values.length;
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _sel = (_sel - 1) % n);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + 1) % n);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      // Only the volume repeats while held; toggles flip once per press.
      if (!repeat || _Item.values[_sel] == _Item.volume) _activate(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
    } else if (k == LogicalKeyboardKey.enter) {
      if (!repeat) _activate(0);
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.keyM) {
      if (!repeat) widget.onClose();
    } else {
      return KeyEventResult.ignored; // F, volume, mute, fullscreen fall through to the TV screen
    }
    return KeyEventResult.handled;
  }

  String _onOff(bool b) => b ? 'ON' : 'OFF';

  String _label(_Item item) {
    final c = widget.current;
    return switch (item) {
      _Item.favorite => c == null ? 'Favorite: -' : 'Favorite ${c.number} ${c.name}: ${s.favorites.contains(c.number) ? 'YES' : 'NO'}',
      _Item.favoritesOnly => 'Flip favorites only: ${_onOff(s.favoritesOnly)}',
      _Item.volume => 'Volume ${'#' * (s.volume ~/ 5)}${'.' * (20 - s.volume ~/ 5)} ${s.volume.round()}',
      _Item.mute => 'Mute: ${_onOff(s.muted)}',
      _Item.startFullscreen => 'Start fullscreen: ${_onOff(s.startFullscreen)}',
      _Item.cornerBug => 'Corner bug: ${_onOff(s.cornerBug)}',
      _Item.block => 'Block this item',
      _Item.refresh => 'Refresh channels',
      _Item.close => 'Close',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: 0.55,
          heightFactor: 0.8,
          child: Container(
            color: _panel,
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, box) {
              final unit = box.maxHeight / (_Item.values.length + 1); // title + items
              final font = (unit * 0.4).clamp(9.0, 26.0);
              TextStyle style(Color color, {bool bold = false}) =>
                  TextStyle(fontFamily: _font, fontSize: font, color: color, fontWeight: bold ? FontWeight.bold : null);
              return Column(children: [
                SizedBox(
                  height: unit,
                  child: Align(alignment: Alignment.centerLeft, child: Text('MENU', style: style(_yellow, bold: true))),
                ),
                for (final (i, item) in _Item.values.indexed)
                  Container(
                    key: i == _sel ? MenuOverlay.selectedKey : null,
                    height: unit - 2,
                    margin: const EdgeInsets.all(1),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    alignment: Alignment.centerLeft,
                    color: i == _sel ? _yellow : _cellBg,
                    child: Text(
                      _label(item),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.clip,
                      style: style(i == _sel ? Colors.black : Colors.white, bold: i == _sel),
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
