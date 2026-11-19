import 'dart:math' as math;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../guide/guide_model.dart';
import 'channel_logo.dart';
import 'touch.dart';

const _font = 'Consolas';
const _panel = Color(0xE6101A5C); // dark translucent blue
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);
const _rows = 5;

/// (background, text) tint for a channel's name cell, by genre.
(Color, Color) genreColors(String genre) => switch (genre) {
      'Kids & Animation' => (const Color(0xFFD32F2F), const Color(0xFFFFEB3B)), // red / yellow
      'Movies' => (const Color(0xFF5E1A7A), const Color(0xFFFF4FD8)), // purple / magenta
      'Comedy & Variety' => (const Color(0xFF00796B), const Color(0xFFFF9800)), // teal / orange
      'Drama & Classic TV' => (const Color(0xFF4E342E), const Color(0xFFFFD180)), // brown / amber
      'News & Docs' => (const Color(0xFF0D1B4A), const Color(0xFFFFC94D)), // navy / gold
      'Music' => (const Color(0xFFE91E8C), const Color(0xFF00E5FF)), // hot pink / electric blue
      'Sports' => (const Color(0xFF2E7D32), const Color(0xFFFFEB3B)), // green / yellow
      'World & Lifestyle' => (const Color(0xFFC62828), const Color(0xFFFFFFFF)), // red / white (green edge)
      _ => (const Color(0xFF37474F), const Color(0xFFFFFFFF)),
    };

String _clock(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')}';
}

const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];

/// 'THU ' when [t] is on a later day than [today], else ''.
String _day(DateTime t, DateTime today) =>
    t.year == today.year && t.month == today.month && t.day == today.day ? '' : '${_days[t.weekday - 1]} ';

/// Retro cable guide drawn over the lower two thirds of the frame; keys move the selection.
class GuideOverlay extends StatefulWidget {
  static const selectedKey = ValueKey('guide-selected');

  final GuideModel model;
  final void Function(Channel) onTune;
  final void Function(Channel) onHighlight;
  final VoidCallback onClose;

  const GuideOverlay({
    super.key,
    required this.model,
    required this.onTune,
    required this.onHighlight,
    required this.onClose,
  });

  @override
  State<GuideOverlay> createState() => _GuideOverlayState();
}

class _GuideOverlayState extends State<GuideOverlay> {
  final _focus = FocusNode();
  GuideModel get m => widget.model;

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

  // Touch (ui/touch.dart): drag up/down scrolls channels a row per row height, left/right steps programmes.
  double _unit = 40, _colW = 40, _dy = 0, _dx = 0;

  void _drag(DragUpdateDetails d, {required bool vertical}) {
    if (vertical) {
      _dy += d.delta.dy;
      while (_dy.abs() >= _unit) {
        _row(_dy > 0 ? -1 : 1); // finger down: earlier channels come into view
        _dy -= _unit * _dy.sign;
      }
    } else {
      _dx += d.delta.dx;
      while (_dx.abs() >= _colW * 2) {
        setState(() => m.moveProgram(_dx > 0 ? -1 : 1)); // finger left: later programmes
        _dx -= _colW * 2 * _dx.sign;
      }
    }
  }

  void _row(int delta) {
    final before = m.selectedChannel;
    setState(() => m.moveRow(delta));
    if (m.selectedChannel != before) widget.onHighlight(m.selectedChannel);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    if (k == LogicalKeyboardKey.arrowUp) {
      _row(-1);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _row(1);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _row(-_rows);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _row(_rows);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      setState(() => m.moveProgram(-1));
    } else if (k == LogicalKeyboardKey.arrowRight) {
      setState(() => m.moveProgram(1));
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) {
      if (!repeat) widget.onTune(m.selectedChannel);
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.keyG) {
      if (!repeat) widget.onClose();
    } else {
      return KeyEventResult.ignored; // volume, mute, fullscreen fall through to the TV screen
    }
    return KeyEventResult.handled;
  }

  TextStyle _style(double size, Color color, {bool bold = false}) =>
      TextStyle(fontFamily: _font, fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : null);

  Widget _text(String s, TextStyle style) => Text(s, maxLines: 1, softWrap: false, overflow: TextOverflow.clip, style: style);

  @override
  Widget build(BuildContext context) {
    final slot = m.selectedSlot;
    final selectedCh = m.selectedChannel;
    final touch = TouchUi.of(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          heightFactor: touch ? 1 : 2 / 3,
          widthFactor: 1,
          child: Container(
            color: _panel,
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, box) {
              // Touch: as many rows as fit at about 56 px each (TV: always five).
              final count = touch ? (box.maxHeight / 56).floor().clamp(5, 16) - 2 : _rows;
              final rows = m.rowsInView(count);
              final unit = box.maxHeight / (count + 2); // header + time row + channel rows
              final font = (unit * 0.32).clamp(9.0, 28.0);
              final nameW = box.maxWidth * (touch && box.maxWidth < 600 ? 0.32 : 0.24); // narrow phone: room for the name
              // Twelve 15-minute columns: shrink the time labels until "12:45" fits a column.
              final colW = (box.maxWidth - nameW) / GuideModel.columnCount;
              final timeFont = math.min(font, colW / 3.3);
              _unit = unit;
              _colW = colW;
              final grid = Column(children: [
                SizedBox(
                  height: unit,
                  child: Row(children: [
                    SizedBox(width: nameW, child: _text(_clock(m.now), _style(font * 1.2, _yellow, bold: true))),
                    Expanded(
                      child: _text(
                        slot == null
                            ? '${selectedCh.name}  ${m.buildingNumbers.contains(selectedCh.number) ? buildingDetail : rows.firstWhere((r) => r.channel == selectedCh).cells.firstOrNull?.label ?? ''}'
                            : '${displayTitle(slot.entry)}  ${_day(slot.start, m.now)}${_clock(slot.start)}-${_clock(slot.end)}${switch (programmeOf(slot.entry).description) {
                                final d? => '  $d',
                                null => '',
                              }}',
                        _style(font, Colors.white, bold: true),
                      ),
                    ),
                  ]),
                ),
                SizedBox(
                  height: unit,
                  child: Row(children: [
                    SizedBox(width: nameW, child: _text(' CH ${_day(m.windowStart, m.now)}', _style(font, _yellow))),
                    for (final col in m.columns)
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.only(left: 2),
                          decoration: const BoxDecoration(border: Border(left: BorderSide(color: _yellow))), // tick
                          child: _text(_clock(col), _style(timeFont, _yellow, bold: true)),
                        ),
                      ),
                  ]),
                ),
                for (final r in rows) SizedBox(height: unit, child: _guideRow(r, r.channel == selectedCh, nameW, font, touch)),
              ]);
              if (!touch) return grid;
              return GestureDetector(
                onVerticalDragStart: (_) => _dy = 0,
                onVerticalDragUpdate: (d) => _drag(d, vertical: true),
                onHorizontalDragStart: (_) => _dx = 0,
                onHorizontalDragUpdate: (d) => _drag(d, vertical: false),
                child: grid,
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _guideRow(GuideRow r, bool selectedRow, double nameW, double font, bool touch) {
    final (bg, fg) = genreColors(r.channel.genre);
    final slot = m.selectedSlot;
    // Touch: tapping the channel tunes it (live, like OK on the TV remote); tapping a programme selects it (the
    // header shows its full title and time), tapping the selected one tunes.
    Widget tap(Widget w, [GuideCell? c]) {
      if (!touch) return w;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (c == null || (selectedRow && (c.slot == null || c.slot == slot))) return widget.onTune(r.channel);
          final before = m.selectedChannel;
          setState(() {
            m.selectedRow = m.channels.indexOf(r.channel);
            m.moveTime(c.slot == null ? Duration.zero : c.slot!.start.difference(m.selectedTime));
          });
          if (m.selectedChannel != before) widget.onHighlight(m.selectedChannel);
        },
        child: w,
      );
    }
    return Row(children: [
      tap(Container(
        width: nameW,
        margin: const EdgeInsets.all(1),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        color: bg,
        child: Row(children: [
          SizedBox(width: nameW * 0.3, child: ChannelLogo(channel: r.channel, height: font * 1.8)),
          const SizedBox(width: 4),
          _text('${m.lockedNumbers.contains(r.channel.number) ? '\u{1F512}' : ''}${r.channel.number} ', _style(font, fg, bold: true)),
          // Long names ("Cablecast East") shrink to fit instead of clipping to a name another row also shows.
          Expanded(
              child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: _text(r.channel.name, _style(font, fg, bold: true)))),
        ]),
      )),
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) => Stack(children: [
            for (final c in r.cells)
              () {
                final sel = selectedRow && (c.slot == null || c.slot == slot);
                final w = (c.endFraction - c.startFraction) * box.maxWidth;
                return Positioned(
                  left: c.startFraction * box.maxWidth,
                  width: w,
                  top: 0,
                  bottom: 0,
                  child: tap(Container(
                    key: sel ? GuideOverlay.selectedKey : null,
                    margin: const EdgeInsets.all(1),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.centerLeft,
                    color: sel ? _yellow : _cellBg,
                    // Under about four characters wide a title is just stray letters; leave the cell blank.
                    child: w < font * 2.5 ? null : _text(c.label, _style(font, sel ? Colors.black : Colors.white, bold: sel)),
                  ), c),
                );
              }(),
          ]),
        ),
      ),
    ]);
  }
}
