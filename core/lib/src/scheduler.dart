import 'models.dart';
import 'seeded_random.dart';

/// One program in a channel's day: [entry] plays from [start] to [end].
/// The last slot of a day is cut at midnight.
class Slot {
  final Entry entry;
  final DateTime start;
  final DateTime end;

  const Slot(this.entry, this.start, this.end);

  Map<String, dynamic> toJson() => {
        'entry': entry.toJson(),
        'start': start.toUtc().toIso8601String(),
        'end': end.toUtc().toIso8601String(),
      };

  factory Slot.fromJson(Map<String, dynamic> j) => Slot(
        Entry.fromJson(j['entry'] as Map<String, dynamic>),
        DateTime.parse(j['start'] as String).toLocal(),
        DateTime.parse(j['end'] as String).toLocal(),
      );
}

/// [d] must be a local DateTime (its y/m/d are the local calendar day).
String dayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// A channel is Off Air when its pool has less than [minSeconds] of content.
bool isOffAir(List<Entry> pool, int minSeconds) =>
    pool.fold(0.0, (s, e) => s + e.durationSeconds) < minSeconds;

/// The shuffled play order for [day] (a local DateTime): the pool sorted by
/// entry id, then shuffled by a seed from `channelKey|date`. Same entries, same
/// order, on every device regardless of the order [pool] arrived in.
List<Entry> dayOrder(List<Entry> pool, String channelKey, DateTime day) {
  if (pool.isEmpty) return [];
  final sorted = [...pool]..sort((a, b) => a.id.compareTo(b.id));
  return seededShuffle(sorted, stableHash('$channelKey|${dayKey(day)}'));
}

/// Lays [order] out back to back from local midnight of [day] (a local
/// DateTime) to the next local midnight, repeating if shorter than a day and
/// cutting the last slot at midnight.
List<Slot> layoutDay(List<Entry> order, DateTime day) {
  if (order.isEmpty) return [];
  final start = DateTime(day.year, day.month, day.day);
  final end = DateTime(day.year, day.month, day.day + 1);
  final slots = <Slot>[];
  var t = start;
  for (var i = 0; t.isBefore(end); i++) {
    final e = order[i % order.length];
    final ms = (e.durationSeconds * 1000).round().clamp(1000, 1 << 40);
    var next = t.add(Duration(milliseconds: ms));
    if (next.isAfter(end)) next = end;
    slots.add(Slot(e, t, next));
    t = next;
  }
  return slots;
}

/// The whole local day for [day] (must be a local DateTime).
List<Slot> scheduleDay(List<Entry> pool, String channelKey, DateTime day) =>
    layoutDay(dayOrder(pool, channelKey, day), day);

/// The slot playing at [t], or null if [slots] doesn't cover it.
Slot? slotAt(List<Slot> slots, DateTime t) {
  for (final s in slots) {
    if (!t.isBefore(s.start) && t.isBefore(s.end)) return s;
  }
  return null;
}

/// Seconds into [slot] that playback should start at time [t].
double offsetSeconds(Slot slot, DateTime t) =>
    t.difference(slot.start).inMilliseconds / 1000.0;

/// The rolling guide: every slot that overlaps [now, now + hours).
/// [dayFor] supplies a day's slots (live shuffle or a saved snapshot).
List<Slot> guide(
  DateTime now,
  List<Slot> Function(DateTime day) dayFor, {
  int hours = 12,
}) {
  final until = now.add(Duration(hours: hours));
  final out = <Slot>[];
  var day = DateTime(now.year, now.month, now.day);
  while (day.isBefore(until)) {
    for (final s in dayFor(day)) {
      if (s.end.isAfter(now) && s.start.isBefore(until)) out.add(s);
    }
    day = DateTime(day.year, day.month, day.day + 1);
  }
  return out;
}
