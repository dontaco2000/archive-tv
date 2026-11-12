import 'dart:math' as math;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../guide/guide_model.dart';
import 'channel_logo.dart';

const _font = 'Consolas';
const _panel = Color(0xE6101A5C); // dark translucent blue
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);
const _rows = 5;

/// (background, text) tint for a channel's name cell, by genre.
(Color, Color) genreColors(String genre) => switch (genre) {
      'Kids & Animation' => (const Color(0xFFD32F2F), const Color(0xFFFFEB3B)), // red / yellow
      'Movies' => (const Color(0xFF5E1A7A), const Color(0xFFFF4FD8)), // purple / magenta
      'TV' => (const Color(0xFF00796B), const Color(0xFFFF9800)), // teal / orange
      'News & Docs' => (const Color(0xFF0D1B4A), const Color(0xFFFFC94D)), // navy / gold
      'Music & Sports' => (const Color(0xFFE91E8C), const Color(0xFF00E5FF)), // hot pink / electric blue
      'International' => (const Color(0xFFC62828), const Color(0xFFFFFFFF)), // red / white (green edge)
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
    final rows = m.rowsInView(_rows);
    final selectedCh = m.selectedChannel;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: FractionallySizedBox(
          heightFactor: 2 / 3,
          widthFactor: 1,
          child: Container(
            color: _panel,
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, box) {
              final unit = box.maxHeight / (_rows + 2); // header + time row + channel rows
              final font = (unit * 0.32).clamp(9.0, 28.0);
              final nameW = box.maxWidth * 0.24;
              // Twelve 15-minute columns: shrink the time labels until "12:45" fits a column.
              final colW = (box.maxWidth - nameW) / GuideModel.columnCount;
              final timeFont = math.min(font, colW / 3.3);
              return Column(children: [
                SizedBox(
                  height: unit,
                  child: Row(children: [
                    SizedBox(width: nameW, child: _text(_clock(m.now), _style(font * 1.2, _yellow, bold: true))),
                    Expanded(
                      child: _text(
                        slot == null
                            ? '${selectedCh.name}  ${m.buildingNumbers.contains(selectedCh.number) ? buildingDetail : rows.firstWhere((r) => r.channel == selectedCh).cells.firstOrNull?.label ?? ''}'
                            : '${cleanTitle(slot.entry.title)}  ${_day(slot.start, m.now)}${_clock(slot.start)}-${_clock(slot.end)}',
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
                for (final r in rows) SizedBox(height: unit, child: _guideRow(r, r.channel == selectedCh, nameW, font)),
              ]);
            }),
          ),
        ),
      ),
    );
  }

  Widget _guideRow(GuideRow r, bool selectedRow, double nameW, double font) {
    final (bg, fg) = genreColors(r.channel.genre);
    final slot = m.selectedSlot;
    return Row(children: [
      Container(
        width: nameW,
        margin: const EdgeInsets.all(1),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        color: bg,
        child: Row(children: [
          SizedBox(width: nameW * 0.3, child: ChannelLogo(channel: r.channel, height: font * 1.8)),
          const SizedBox(width: 4),
          _text('${m.lockedNumbers.contains(r.channel.number) ? '\u{1F512}' : ''}${r.channel.number} ', _style(font, fg, bold: true)),
          Expanded(child: _text(r.channel.name, _style(font, fg, bold: true))),
        ]),
      ),
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
                  child: Container(
                    key: sel ? GuideOverlay.selectedKey : null,
                    margin: const EdgeInsets.all(1),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.centerLeft,
                    color: sel ? _yellow : _cellBg,
                    // Under about four characters wide a title is just stray letters; leave the cell blank.
                    child: w < font * 2.5 ? null : _text(c.label, _style(font, sel ? Colors.black : Colors.white, bold: sel)),
                  ),
                );
              }(),
          ]),
        ),
      ),
    ]);
  }
}
