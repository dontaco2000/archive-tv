import 'package:archive_tv_core/archive_tv_core.dart';

/// Guide cell for a channel whose pool is still building.
const buildingLabel = 'BUILDING...';

/// Guide cell for a parental-locked channel.
const lockedLabel = 'LOCKED';

/// The guide's detail line for a selected building channel.
const buildingDetail = 'Building... please choose another channel for now';

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
/// The time grid is in 15-minute steps; rows hold guide blocks (see `guideBlocks`) and
/// Left/Right walk the selected row block by block.
class GuideModel {
  static const step = Duration(minutes: 15);
  static const columnCount = 12; // three hours on screen

  final List<Channel> channels;
  final List<Slot> Function(Channel) slotsFor;
  final DateTime now;
  final Set<int> tunableNumbers;

  /// Non-tunable channels whose pool is still building (shown as [buildingLabel], not OFF AIR).
  final Set<int> buildingNumbers;

  /// Parental-locked channels: one "LOCKED" cell, programme titles hidden.
  final Set<int> lockedNumbers;

  /// Nothing can be selected at or after this; [slotsFor] should not reach past it either.
  final DateTime horizon;
  final Duration visible = step * columnCount;

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
    Set<int>? buildingNumbers,
    Set<int>? lockedNumbers,
    DateTime? horizon,
  })  : buildingNumbers = buildingNumbers ?? {},
        lockedNumbers = lockedNumbers ?? {},
        horizon = horizon ?? now.add(const Duration(hours: 12)) {
    windowStart = floor(now);
    selectedTime = now;
  }

  /// [t] rounded down to the quarter hour.
  static DateTime floor(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute - t.minute % 15);

  List<DateTime> get columns => [for (var i = 0; i < columnCount; i++) windowStart.add(step * i)];

  Channel get selectedChannel => channels[selectedRow];

  bool _tunable(Channel c) => tunableNumbers.contains(c.number);

  /// The row's guide blocks (see `guideBlocks`): short items, same-show runs and short-content
  /// channels are grouped for display; tuning still plays the real schedule.
  List<Slot> _slotsOf(Channel c) => lockedNumbers.contains(c.number) ? const [] : _slots[c.number] ??= guideBlocks(slotsFor(c), shortContent: c.shortContent, labelOf: (e) => blockLabelOf(c, e), themeOf: (s) => themeLabelOf(c, s));

  Slot? get selectedSlot => _tunable(selectedChannel) ? slotAt(_slotsOf(selectedChannel), selectedTime) : null;

  /// Up/Down: the time cursor stays put, so the new row selects whatever airs then.
  void moveRow(int delta) => selectedRow = (selectedRow + delta).clamp(0, channels.length - 1);

  /// Moves the time cursor by [delta] (clamped to now; ignored at the horizon).
  void moveTime(Duration delta) {
    final t = selectedTime.add(delta);
    if (!t.isBefore(horizon)) return;
    _select(t);
  }

  /// Right (+1) selects the next program in the row, Left (-1) the previous one, never before
  /// the one airing now. Rows without programs step 15 minutes instead. Stops at the horizon.
  void moveProgram(int dir) {
    final slots = _tunable(selectedChannel) ? _slotsOf(selectedChannel) : const <Slot>[];
    if (slots.isEmpty) return moveTime(step * dir);
    final from = selectedSlot?.start ?? selectedTime;
    final Slot? target = dir > 0
        ? slots.where((s) => s.start.isAfter(from) && s.start.isBefore(horizon)).firstOrNull
        : slots.where((s) => s.start.isBefore(from)).lastOrNull;
    if (target == null) {
      if (dir < 0) _select(now);
      return;
    }
    _select(target.start);
  }

  void _select(DateTime t) {
    selectedTime = t.isBefore(now) ? now : t;
    if (selectedTime.isBefore(windowStart) || !selectedTime.isBefore(windowStart.add(visible))) {
      windowStart = floor(selectedTime); // the selected program starts in the first column
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
    if (lockedNumbers.contains(c.number)) return GuideRow(c, true, [GuideCell(null, lockedLabel, 0, 1)]);
    if (c.type == 'weatherstar') return GuideRow(c, true, [GuideCell(null, 'WeatherStar: Local Forecast', 0, 1)]);
    if (!_tunable(c)) {
      final label = buildingNumbers.contains(c.number) ? buildingLabel : (c.type == 'archive' ? 'OFF AIR' : 'NOT AVAILABLE');
      return GuideRow(c, false, [GuideCell(null, label, 0, 1)]);
    }
    final end = windowStart.add(visible);
    final total = visible.inMilliseconds;
    double frac(DateTime t) => t.difference(windowStart).inMilliseconds / total;
    return GuideRow(c, true, [
      for (final s in _slotsOf(c))
        if (s.end.isAfter(windowStart) && s.start.isBefore(end))
          GuideCell(s, cleanTitle(s.entry.title), frac(s.start).clamp(0.0, 1.0), frac(s.end).clamp(0.0, 1.0)),
    ]);
  }
}
