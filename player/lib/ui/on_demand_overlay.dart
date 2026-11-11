import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'arcade_entry.dart';

const _font = 'Consolas';
const _panel = Color(0xF0101A5C);
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);

enum _View { shelves, titles, searchEntry, searchResults }

/// On Demand: channels as shelves (SEARCH first), a shelf's titles, or an arcade-style
/// three-letter search over every shelf. Enter on a title calls [onPlay].
class OnDemandOverlay extends StatefulWidget {
  final List<Channel> channels;
  final List<Entry> Function(Channel) poolOf;
  final void Function(Channel, Entry) onPlay;
  final VoidCallback onClose;

  const OnDemandOverlay({super.key, required this.channels, required this.poolOf, required this.onPlay, required this.onClose});

  @override
  State<OnDemandOverlay> createState() => _OnDemandOverlayState();
}

class _OnDemandOverlayState extends State<OnDemandOverlay> {
  final _focus = FocusNode();
  final _search = ArcadeEntry(3);
  _View _view = _View.shelves;
  int _shelf = 0; // 0 = SEARCH, then channels
  int _sel = 0;
  int _scroll = 0;
  List<(Channel, Entry)> _items = const [];

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

  void _show(_View v, [List<(Channel, Entry)>? items]) {
    _view = v;
    if (items != null) {
      _items = items;
      _sel = 0;
      _scroll = 0;
    }
  }

  // Every title of every shelf, cleaned and sorted once, so each letter change is a plain scan.
  late final List<(String, Channel, Entry)> _catalog = () {
    final all = [
      for (final c in widget.channels)
        for (final e in widget.poolOf(c))
          if (cleanTitle(e.title) case final t) (t.toLowerCase(), naturalKey(t), c, e),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final x in all) (x.$1, x.$3, x.$4)];
  }();

  // ponytail: capped at 300 hits; one letter can match thousands of ~27k titles.
  List<(Channel, Entry)> _searchAll() {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return const [];
    // Titles with a word starting with the letters come first, then any other match.
    final word = [for (final (t, c, e) in _catalog) if (t.startsWith(q) || t.contains(' $q')) (c, e)];
    final rest = [for (final (t, c, e) in _catalog) if (!(t.startsWith(q) || t.contains(' $q')) && t.contains(q)) (c, e)];
    return [...word, ...rest].take(300).toList();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final enter = (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) && e is! KeyRepeatEvent;
    final back = k == LogicalKeyboardKey.escape && e is! KeyRepeatEvent;
    int move(int sel, int count) {
      if (k == LogicalKeyboardKey.arrowUp) return (sel - 1).clamp(0, count - 1);
      if (k == LogicalKeyboardKey.arrowDown) return (sel + 1).clamp(0, count - 1);
      if (k == LogicalKeyboardKey.pageUp) return (sel - 10).clamp(0, count - 1);
      if (k == LogicalKeyboardKey.pageDown) return (sel + 10).clamp(0, count - 1);
      return sel;
    }

    switch (_view) {
      case _View.shelves:
        if (enter || k == LogicalKeyboardKey.arrowRight) {
          setState(() => _shelf == 0
              ? _show(_View.searchEntry, _searchAll())
              : _show(_View.titles, [for (final t in searchTitles(widget.poolOf(widget.channels[_shelf - 1]), '')) (widget.channels[_shelf - 1], t)]));
        } else if (back || k == LogicalKeyboardKey.arrowLeft) {
          widget.onClose();
        } else {
          setState(() => _shelf = move(_shelf, widget.channels.length + 1));
        }
      case _View.searchEntry:
        if (enter) {
          if (_items.isNotEmpty) setState(() => _show(_View.searchResults));
        } else if (back) {
          setState(() => _show(_View.shelves));
        } else if (_search.handleKey(e)) {
          setState(() => _show(_View.searchEntry, _searchAll()));
        } else {
          return KeyEventResult.ignored;
        }
      case _View.titles || _View.searchResults:
        if (enter && _items.isNotEmpty) {
          final (c, t) = _items[_sel];
          widget.onPlay(c, t);
        } else if (back || k == LogicalKeyboardKey.arrowLeft) {
          setState(() => _show(_view == _View.titles ? _View.shelves : _View.searchEntry));
        } else {
          setState(() => _sel = move(_sel, _items.length));
        }
    }
    return KeyEventResult.handled;
  }

  String _len(Entry e) {
    final m = (e.durationSeconds / 60).round();
    return m >= 60 ? '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (_view) {
      _View.shelves => 'ON DEMAND',
      _View.titles => 'ON DEMAND > ${_items.firstOrNull?.$1.name.toUpperCase() ?? ''}',
      _ => 'SEARCH',
    };
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        color: _panel,
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(builder: (context, box) {
          final unit = box.maxHeight / 13;
          final font = (unit * 0.45).clamp(9.0, 24.0);
          TextStyle style(Color c, {bool bold = false}) =>
              TextStyle(fontFamily: _font, fontSize: font, color: c, fontWeight: bold ? FontWeight.bold : null);
          Widget row(String text, bool selected, {String? right}) => Container(
                height: unit - 2,
                margin: const EdgeInsets.all(1),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: selected ? _yellow : _cellBg,
                child: Row(children: [
                  Expanded(
                    child: Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style(selected ? Colors.black : Colors.white, bold: selected)),
                  ),
                  if (right != null) Text(right, style: style(selected ? Colors.black : const Color(0xFF9EC8FF))),
                ]),
              );

          final searching = _view == _View.searchEntry || _view == _View.searchResults;
          final header = <Widget>[
            SizedBox(height: unit, child: Align(alignment: Alignment.centerLeft, child: Text(title, style: style(_yellow, bold: true)))),
            if (searching)
              SizedBox(
                height: unit * 2,
                child: Row(children: [
                  FittedBox(child: ArcadeEntryView(entry: _search, active: _view == _View.searchEntry, size: font * 1.4)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _view == _View.searchEntry ? 'Up/Down letter, Left/Right move, Enter: results' : 'Enter plays, Esc: back to letters',
                      style: style(const Color(0xFF9EC8FF)),
                      maxLines: 2,
                    ),
                  ),
                ]),
              ),
          ];
          final visible = (13 - (searching ? 3 : 1)).clamp(1, 13);

          final List<Widget> rows;
          if (_view == _View.shelves) {
            final labels = ['SEARCH', for (final c in widget.channels) '${c.number}  ${c.name.toUpperCase()}'];
            final start = (_shelf - visible + 1).clamp(0, labels.length);
            rows = [
              for (var i = start; i < labels.length && i < start + visible; i++)
                row(labels[i], i == _shelf, right: i == 0 ? null : '${widget.poolOf(widget.channels[i - 1]).length} titles'),
            ];
          } else {
            if (_sel < _scroll) _scroll = _sel;
            if (_sel >= _scroll + visible) _scroll = _sel - visible + 1;
            final showSel = _view != _View.searchEntry;
            rows = [
              if (_items.isEmpty)
                row(searching ? (_search.text.trim().isEmpty ? 'Pick letters to search' : 'No matches') : 'Nothing here yet', false),
              for (var i = _scroll; i < _items.length && i < _scroll + visible; i++)
                row(
                  cleanTitle(_items[i].$2.title),
                  showSel && i == _sel,
                  right: searching ? '${_items[i].$1.name}  ${_len(_items[i].$2)}' : _len(_items[i].$2),
                ),
            ];
          }
          return Column(children: [...header, ...rows]);
        }),
      ),
    );
  }
}
