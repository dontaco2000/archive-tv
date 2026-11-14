import 'dart:io' show Platform;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../input/gamepad.dart' show keyEvent;
import 'arcade_entry.dart';
import 'touch.dart';
import '../guide/guide_model.dart';

const _font = 'Consolas';
const _panel = Color(0xF0101A5C);
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);
const _blue = Color(0xFF9EC8FF);

/// The first row of the genre list.
const searchLabel = 'SEARCH  (type to find a show)';

/// The last row of a genre's shows: its single films and one-offs.
const specialsLabel = 'Movies & specials';

enum _View { genres, shows, episodes, searchEntry, searchResults }

/// One genre's shows (all its channels merged; [specialsLabel] last) and each entry's channel.
class _Genre {
  final String name;
  final List<ShowGroup> rows;
  final Map<String, Channel> channelOf;
  _Genre(this.name, this.rows, this.channelOf);
}

/// A search result: a show (opens its episodes) or one episode (plays).
class _Hit {
  final _Genre genre;
  final ShowGroup? show;
  final Entry? entry;
  _Hit(this.genre, {this.show, this.entry});
}

/// On Demand: SEARCH, then the guide's genres -> the genre's shows (every channel of the genre merged, by show
/// name; single films last under [specialsLabel]) -> a show's episodes; Enter on an episode calls [onPlay].
/// Back/Esc goes up one level, keeping the position. Search matches show names first, then episode titles: on
/// Windows and touch screens it is a text field (type directly / the soft keyboard), on a TV remote the arcade
/// three-letter entry. Rows of R-rated entries ([isRated]) carry an R tag; [poolOf] already leaves out what the
/// parental setting hides.
class OnDemandOverlay extends StatefulWidget {
  final List<Channel> channels;
  final List<Entry> Function(Channel) poolOf;
  final void Function(Channel, Entry) onPlay;
  final VoidCallback onClose;
  final bool Function(Channel, Entry)? isRated;

  /// Text field search; null = on phones/tablets and off Android (Windows), arcade letters on Android TV.
  final bool? textSearch;

  const OnDemandOverlay({
    super.key,
    required this.channels,
    required this.poolOf,
    required this.onPlay,
    required this.onClose,
    this.isRated,
    this.textSearch,
  });

  @override
  State<OnDemandOverlay> createState() => _OnDemandOverlayState();
}

class _OnDemandOverlayState extends State<OnDemandOverlay> {
  final _focus = FocusNode();
  final _fieldFocus = FocusNode();
  final _text = TextEditingController();
  final _arcade = ArcadeEntry(3);
  _View _view = _View.genres;
  bool _loading = false;

  late final List<String> _genres = {for (final c in widget.channels) if (c.genre.isNotEmpty) c.genre}.toList();
  int _genreRow = 0; // 0 = SEARCH, then [_genres]
  _Genre? _genre;
  int _showRow = 0;
  ShowGroup? _show;
  _View _showFrom = _View.shows; // where Back from the episodes goes
  int _episodeRow = 0;
  List<_Hit> _hits = const [];
  int _hitRow = 0;
  int _scroll = 0;

  // ponytail: Fire Stick memory: a genre's shows are built when it is opened and only the last two are kept;
  // search builds every genre once (references into the pools, no copies) and drops it on leaving search.
  final _cache = <String, _Genre>{}; // insertion-ordered: oldest first
  List<_Genre>? _index;
  List<(String, _Hit)>? _episodeIndex; // lower-case display title -> hit

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
    _fieldFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  bool get _textMode => widget.textSearch ?? (TouchUi.of(context) || !Platform.isAndroid);

  _Genre _build(String g) {
    final channelOf = <String, Channel>{};
    final entries = <Entry>[];
    for (final c in widget.channels) {
      if (c.genre != g) continue;
      for (final e in widget.poolOf(c)) {
        if (channelOf.putIfAbsent(e.id, () => c) == c) entries.add(e);
      }
    }
    final l = groupShows(entries, itemInfo: itemInfoOf);
    return _Genre(g, [...l.shows, if (l.singles.isNotEmpty) ShowGroup(specialsLabel, l.singles)], channelOf);
  }

  _Genre _genreData(String g) {
    for (final x in _index ?? const <_Genre>[]) {
      if (x.name == g) return x;
    }
    final hit = _cache.remove(g) ?? _build(g);
    _cache[g] = hit; // most recent last
    while (_cache.length > 2) {
      _cache.remove(_cache.keys.first);
    }
    return hit;
  }

  /// Shows "Loading..." for a frame, then runs [work] (grouping a big genre takes a moment on a Fire Stick).
  void _later(void Function() work) {
    setState(() => _loading = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        work();
        _loading = false;
      });
    });
  }

  void _openGenre(int row) {
    _later(() {
      _genre = _genreData(_genres[row - 1]);
      _view = _View.shows;
      _showRow = 0;
    });
  }

  void _openShow(ShowGroup s, _Genre g, _View from) {
    _genre = g;
    _show = s;
    _showFrom = from;
    _view = _View.episodes;
    _episodeRow = 0;
  }

  void _openSearch() {
    _view = _View.searchEntry;
    if (_textMode) _fieldFocus.requestFocus();
    _runSearch();
  }

  String get _query => (_textMode ? _text.text : _arcade.text).trim();

  void _runSearch() {
    final q = _query;
    _hitRow = 0;
    if (q.length < (_textMode ? 2 : 1)) {
      _hits = const [];
      return;
    }
    final index = _index ??= [for (final g in _genres) _cache[g] ?? _build(g)];
    final episodes = _episodeIndex ??= [
      for (final g in index)
        for (final s in g.rows)
          for (final e in s.entries) (displayTitle(e).toLowerCase(), _Hit(g, entry: e)),
    ];
    final shows = [
      for (final g in index)
        for (final s in g.rows)
          if (!identical(s.name, specialsLabel)) _Hit(g, show: s),
    ];
    // ponytail: capped at 300 rows; two letters can match thousands of ~30k titles.
    _hits = [
      ...rankMatches(shows, (h) => h.show!.name, q),
      ...rankMatches(episodes, (x) => x.$1, q).map((x) => x.$2),
    ].take(300).toList();
  }

  void _leaveSearch() {
    _view = _View.genres;
    _index = null;
    _episodeIndex = null;
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent || _loading) return e is KeyUpEvent ? KeyEventResult.ignored : KeyEventResult.handled;
    final k = e.logicalKey;
    final enter = (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) && e is! KeyRepeatEvent;
    final back = k == LogicalKeyboardKey.escape && e is! KeyRepeatEvent;
    final left = k == LogicalKeyboardKey.arrowLeft, right = k == LogicalKeyboardKey.arrowRight;
    int move(int sel, int count) => switch (k) {
          LogicalKeyboardKey.arrowUp => (sel - 1).clamp(0, count - 1),
          LogicalKeyboardKey.arrowDown => (sel + 1).clamp(0, count - 1),
          LogicalKeyboardKey.pageUp => (sel - 10).clamp(0, count - 1),
          LogicalKeyboardKey.pageDown => (sel + 10).clamp(0, count - 1),
          _ => sel,
        };

    switch (_view) {
      case _View.genres:
        if (enter || right) {
          if (_genreRow == 0) {
            setState(_openSearch);
          } else {
            _openGenre(_genreRow);
          }
        } else if (back || left) {
          widget.onClose();
        } else {
          setState(() => _genreRow = move(_genreRow, _genres.length + 1));
        }
      case _View.shows:
        final rows = _genre!.rows;
        if ((enter || right) && rows.isNotEmpty) {
          setState(() => _openShow(rows[_showRow], _genre!, _View.shows));
        } else if (back || left) {
          setState(() => _view = _View.genres);
        } else {
          setState(() => _showRow = move(_showRow, rows.length));
        }
      case _View.episodes:
        final eps = _show!.entries;
        if (enter && eps.isNotEmpty) {
          final ep = eps[_episodeRow];
          widget.onPlay(_genre!.channelOf[ep.id]!, ep);
        } else if (back || left) {
          setState(() {
            _view = _showFrom;
            if (_showFrom == _View.searchResults) _focus.requestFocus();
          });
        } else {
          setState(() => _episodeRow = move(_episodeRow, eps.length));
        }
      case _View.searchEntry:
        if (enter) {
          if (_hits.isNotEmpty) setState(() => _view = _View.searchResults);
        } else if (back) {
          setState(_leaveSearch);
        } else if (_textMode) {
          _fieldFocus.requestFocus(); // typing belongs to the field
          return KeyEventResult.ignored;
        } else if (_arcade.handleKey(e)) {
          setState(_runSearch);
        } else {
          return KeyEventResult.ignored;
        }
      case _View.searchResults:
        if (enter && _hits.isNotEmpty) {
          final h = _hits[_hitRow];
          if (h.show != null) {
            setState(() => _openShow(h.show!, h.genre, _View.searchResults));
          } else {
            widget.onPlay(h.genre.channelOf[h.entry!.id]!, h.entry!);
          }
        } else if (back || left || (_textMode && k == LogicalKeyboardKey.arrowUp && _hitRow == 0)) {
          setState(() {
            _view = _View.searchEntry;
            if (_textMode) _fieldFocus.requestFocus();
          });
        } else {
          setState(() => _hitRow = move(_hitRow, _hits.length));
        }
    }
    return KeyEventResult.handled;
  }

  /// Keys while the search text field has focus: Esc leaves search, Enter/Down go to the results, editing keys go
  /// on to the text field's shortcuts, everything else is typing (kept from the TV's hotkeys: "m" is not mute here).
  KeyEventResult _onFieldKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      setState(_leaveSearch);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.arrowDown) {
      if (_hits.isNotEmpty) {
        setState(() => _view = _View.searchResults);
        _focus.requestFocus();
      }
    } else if (k == LogicalKeyboardKey.arrowUp) {
      // nothing above the field
    } else if (const {'Arrow Left', 'Arrow Right', 'Backspace', 'Delete', 'Home', 'End'}.contains(k.keyLabel)) {
      return KeyEventResult.ignored;
    } else {
      return KeyEventResult.skipRemainingHandlers;
    }
    return KeyEventResult.handled;
  }

  String _len(Entry e) {
    final m = (e.durationSeconds / 60).round();
    return m >= 60 ? '${m ~/ 60}h${(m % 60).toString().padLeft(2, '0')}' : '${m}m';
  }

  bool _rated(_Genre g, Entry e) => widget.isRated?.call(g.channelOf[e.id]!, e) ?? false;

  String _episodes(ShowGroup s) {
    final n = s.entries.length;
    return '$n ${identical(s.name, specialsLabel) ? 'title' : 'episode'}${n == 1 ? '' : 's'}';
  }

  @override
  Widget build(BuildContext context) {
    final g = _genre, s = _show;
    final title = switch (_view) {
      _View.genres => 'ON DEMAND',
      _View.shows => 'ON DEMAND > ${g!.name.toUpperCase()}',
      _View.episodes => '${_showFrom == _View.searchResults ? 'SEARCH' : 'ON DEMAND > ${g!.name.toUpperCase()}'} > ${s!.name.toUpperCase()}',
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
          // A tap (touch or mouse) selects the row and acts as Enter.
          void tap(void Function() select) {
            if (_loading) return;
            setState(select);
            if (_view == _View.searchEntry) setState(() => _view = _View.searchResults);
            _focus.requestFocus();
            _onKey(_focus, keyEvent(LogicalKeyboardKey.enter, down: true));
          }

          final unit = box.maxHeight / 13;
          final font = (unit * 0.45).clamp(9.0, 24.0);
          TextStyle style(Color c, {bool bold = false}) =>
              TextStyle(fontFamily: _font, fontSize: font, color: c, fontWeight: bold ? FontWeight.bold : null);
          Widget row(String text, bool selected, {String? right, bool rated = false, VoidCallback? onTap}) => GestureDetector(
                onTap: onTap,
                child: Container(
                  height: unit - 2,
                  margin: const EdgeInsets.all(1),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  color: selected ? _yellow : _cellBg,
                  child: Row(children: [
                    if (rated)
                      Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        color: const Color(0xFFC62828),
                        child: Text('R', style: style(Colors.white, bold: true).copyWith(fontSize: font * 0.8)),
                      ),
                    Expanded(
                      child: Text(text, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: style(selected ? Colors.black : Colors.white, bold: selected)),
                    ),
                    if (right != null) Text(right, style: style(selected ? Colors.black : _blue)),
                  ]),
                ),
              );

          final searching = _view == _View.searchEntry || _view == _View.searchResults;
          final narrow = box.maxWidth < 600; // phones: titles get the width, no hint or channel names
          final Widget entryBox = _textMode
              ? DefaultTextEditingShortcuts(
                  child: Focus(
                    onKeyEvent: _onFieldKey,
                    child: TextField(
                      controller: _text,
                      focusNode: _fieldFocus,
                      autofocus: _view == _View.searchEntry,
                      onTap: () => setState(() => _view = _View.searchEntry),
                      onChanged: (_) => setState(_runSearch),
                      cursorColor: _yellow,
                      style: style(Colors.white, bold: true).copyWith(fontSize: font * 1.3),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        fillColor: _cellBg,
                        hintText: 'Show or episode name',
                        hintStyle: style(_blue),
                        border: const OutlineInputBorder(borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                )
              : FittedBox(child: ArcadeEntryView(entry: _arcade, active: _view == _View.searchEntry, size: font * 1.4));
          final header = <Widget>[
            SizedBox(height: unit, child: Align(alignment: Alignment.centerLeft, child: Text(title, style: style(_yellow, bold: true)))),
            if (searching)
              SizedBox(
                height: unit * 2,
                child: Row(children: [
                  if (_textMode) Expanded(flex: 3, child: entryBox) else entryBox,
                  const SizedBox(width: 16),
                  if (!narrow) Expanded(
                    flex: 2,
                    child: Text(
                      _view == _View.searchResults
                          ? 'Enter: open/play, Esc: back to the search'
                          : _textMode
                              ? 'Type 2+ letters. Enter or Down: results'
                              : 'Up/Down letter, Left/Right move, Enter: results',
                      style: style(_blue),
                      maxLines: 2,
                    ),
                  ),
                ]),
              ),
          ];
          final visible = (13 - (searching ? 3 : 1)).clamp(1, 13);

          // The selected row stays in view; a level's rows scroll under it.
          List<Widget> window(int sel, int count, Widget Function(int i) build) {
            if (sel < _scroll) _scroll = sel;
            if (sel >= _scroll + visible) _scroll = sel - visible + 1;
            _scroll = _scroll.clamp(0, (count - visible).clamp(0, count));
            return [for (var i = _scroll; i < count && i < _scroll + visible; i++) build(i)];
          }

          final List<Widget> rows;
          if (_loading) {
            rows = [row('Loading shows...', false)];
          } else {
            switch (_view) {
              case _View.genres:
                rows = window(_genreRow, _genres.length + 1, (i) => row(i == 0 ? searchLabel : _genres[i - 1], i == _genreRow, onTap: () => tap(() => _genreRow = i)));
              case _View.shows:
                final list = g!.rows;
                rows = list.isEmpty
                    ? [row('Nothing here yet', false)]
                    : window(_showRow, list.length, (i) {
                        final sh = list[i];
                        return row(sh.name, i == _showRow,
                            right: _episodes(sh), rated: sh.entries.any((e) => _rated(g, e)), onTap: () => tap(() => _showRow = i));
                      });
              case _View.episodes:
                final eps = s!.entries;
                final specials = identical(s.name, specialsLabel);
                rows = window(_episodeRow, eps.length, (i) {
                  final e = eps[i];
                  return row(specials ? displayTitle(e) : episodeLabel(s.name, displayTitle(e)), i == _episodeRow,
                      right: _len(e), rated: _rated(g!, e), onTap: () => tap(() => _episodeRow = i));
                });
              case _View.searchEntry || _View.searchResults:
                final showSel = _view == _View.searchResults;
                rows = _hits.isEmpty
                    ? [row(_query.length < (_textMode ? 2 : 1) ? (_textMode ? 'Type at least 2 letters' : 'Pick letters to search') : 'No matches', false)]
                    : window(_hitRow, _hits.length, (i) {
                        final h = _hits[i];
                        final sh = h.show;
                        return sh != null
                            ? row('${sh.name}  (${_episodes(sh)})', showSel && i == _hitRow,
                                right: narrow ? null : h.genre.name, rated: sh.entries.any((e) => _rated(h.genre, e)), onTap: () => tap(() => _hitRow = i))
                            : row(displayTitle(h.entry!), showSel && i == _hitRow,
                                right: narrow ? _len(h.entry!) : '${h.genre.channelOf[h.entry!.id]!.name}  ${_len(h.entry!)}',
                                rated: _rated(h.genre, h.entry!),
                                onTap: () => tap(() => _hitRow = i));
                      });
            }
          }
          return Column(children: [...header, ...rows]);
        }),
      ),
    );
  }
}
