import 'package:archive_tv_core/archive_tv_core.dart';

/// One block in a guide row. [slot] is null for the placeholder of a channel that is not tunable.
/// Fractions are of the visible window, clipped to 0..1.
class GuideCell {
  final Slot? slot;
  final String label;
  final double startFraction;
  final double endFraction;

  const GuideCell(this.slot, this.label, this.startFraction, this.endFraction);
}

class GuideRow {
  final Channel channel;
  final bool tunable;
  final List<GuideCell> cells;

  const GuideRow(this.channel, this.tunable, this.cells);
}

/// Selection, window and rows of the TV guide. Pure logic, no widgets.
class GuideModel {
  static const _half = Duration(minutes: 30);
  static const _span = Duration(hours: 12);

  final List<Channel> channels;
  final List<Slot> Function(Channel) slotsFor;
  final DateTime now;
  final Set<int> tunableNumbers;
  final Duration visible = const Duration(hours: 3);

  late DateTime windowStart;
  int selectedRow = 0;
  late DateTime selectedTime;
  int _scroll = 0;
  final Map<int, List<Slot>> _slots = {};

  GuideModel({
    required this.channels,
    required this.slotsFor,
    required this.now,
    required this.tunableNumbers,
  }) {
    windowStart = _floor(now);
    selectedTime = now;
  }

  static DateTime _floor(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute < 30 ? 0 : 30);

  List<DateTime> get columns => [for (var i = 0; i < 6; i++) windowStart.add(_half * i)];

  Channel get selectedChannel => channels[selectedRow];

  bool _tunable(Channel c) => tunableNumbers.contains(c.number);

  List<Slot> _slotsOf(Channel c) => _slots[c.number] ??= slotsFor(c);

  Slot? get selectedSlot => _tunable(selectedChannel) ? slotAt(_slotsOf(selectedChannel), selectedTime) : null;

  void moveRow(int delta) => selectedRow = (selectedRow + delta).clamp(0, channels.length - 1);

  void moveTime(Duration delta) {
    final t = selectedTime.add(delta);
    if (t.isBefore(now)) {
      selectedTime = now;
    } else if (t.isBefore(now.add(_span))) {
      selectedTime = t;
    } else {
      return;
    }
    if (selectedTime.isBefore(windowStart)) {
      windowStart = _floor(selectedTime);
    } else if (!selectedTime.isBefore(windowStart.add(visible))) {
      windowStart = _floor(selectedTime).subtract(visible - _half);
    }
  }

  List<GuideRow> rowsInView(int count) {
    count = count.clamp(0, channels.length);
    if (selectedRow < _scroll) _scroll = selectedRow;
    if (selectedRow >= _scroll + count) _scroll = selectedRow - count + 1;
    _scroll = _scroll.clamp(0, channels.length - count);
    return [for (final c in channels.skip(_scroll).take(count)) _row(c)];
  }

  GuideRow _row(Channel c) {
    if (!_tunable(c)) {
      return GuideRow(c, false, [GuideCell(null, c.type == 'archive' ? 'OFF AIR' : 'NOT AVAILABLE', 0, 1)]);
    }
    final end = windowStart.add(visible);
    final total = visible.inMilliseconds;
    double frac(DateTime t) => t.difference(windowStart).inMilliseconds / total;
    return GuideRow(c, true, [
      for (final s in _slotsOf(c))
        if (s.end.isAfter(windowStart) && s.start.isBefore(end))
          GuideCell(s, s.entry.title, frac(s.start).clamp(0.0, 1.0), frac(s.end).clamp(0.0, 1.0)),
    ]);
  }
}
