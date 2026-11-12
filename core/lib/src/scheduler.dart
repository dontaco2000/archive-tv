import 'dart:math' show min;

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

/// One night's serial block: up to [count] of [episodes] (the day's picks plus spares that stand in
/// for blocked/broken ones) from [startMinute] (after local midnight), nominally [minutes] long.
class SerialBlock {
  final int startMinute;
  final int minutes;
  final int count;
  final List<Entry> episodes;

  const SerialBlock(this.startMinute, this.minutes, this.count, this.episodes);

  SerialBlock withEpisodes(List<Entry> e) => SerialBlock(startMinute, minutes, count, e);

  Map<String, dynamic> toJson() => {
        'start': startMinute,
        'minutes': minutes,
        'count': count,
        'episodes': [for (final e in episodes) e.toJson()],
      };

  factory SerialBlock.fromJson(Map<String, dynamic> j) => SerialBlock(
        j['start'] as int,
        j['minutes'] as int,
        j['count'] as int,
        [for (final e in (j['episodes'] as List).cast<Map<String, dynamic>>()) Entry.fromJson(e)],
      );
}

/// [channel]'s serial blocks for [day]; [episodes] is `[slot][show]` (see `buildSerialEpisodes`).
/// No stored state: the first episode is `((day - epoch) * perDay) mod N` over the slot's whole
/// queue (shows back to back, looping). Slots with no episodes are left out.
List<SerialBlock> serialBlocks(Channel channel, List<List<List<Entry>>> episodes, DateTime day, {int spares = 3}) {
  final out = <SerialBlock>[];
  for (final (k, slot) in channel.serials.indexed) {
    final flat = [if (k < episodes.length) for (final show in episodes[k]) ...show];
    if (flat.isEmpty) continue;
    final minutes = channel.primeTime.slotMinutes;
    final perDay = slot.perDay ?? _perDay(flat, minutes);
    final days = DateTime.utc(day.year, day.month, day.day)
        .difference(DateTime.utc(slot.epoch.year, slot.epoch.month, slot.epoch.day))
        .inDays;
    final first = (days * perDay) % flat.length; // Dart's % is never negative here
    final take = perDay + spares < flat.length ? perDay + spares : flat.length;
    out.add(SerialBlock(slot.startMinute, minutes, perDay, [for (var i = 0; i < take; i++) flat[(first + i) % flat.length]]));
  }
  return out;
}

/// How many episodes of median length fit [minutes] (at least 1).
int _perDay(List<Entry> eps, int minutes) {
  final d = [for (final e in eps) e.durationSeconds]..sort();
  final n = (minutes * 60 / d[d.length ~/ 2]).floor();
  return n < 1 ? 1 : n;
}

Source? _sourceOf(Channel c, Entry e) {
  final i = e.source;
  return i != null && i >= 0 && i < c.sources.length ? c.sources[i] : null;
}

/// Entry comes from a "rare" source (one with `perDay`) and is at least its `perDayMinMinutes` long:
/// it airs only in [rareBlocks], never in the shuffle.
bool isRare(Channel c, Entry e) => switch (_sourceOf(c, e)) {
      final s? => s.perDay != null && e.durationSeconds >= s.perDayMinMinutes * 60,
      _ => false,
    };

/// The guide label for [e]'s source (`blockLabel`), or null. For a `perDay` source only its rare
/// entries get it, so a short clip from the shuffle next to the day's race doesn't make a "Marathon".
String? blockLabelOf(Channel c, Entry e) => switch (_sourceOf(c, e)) {
      final s? when s.perDay == null || isRare(c, e) => s.blockLabel,
      _ => null,
    };

/// How many entries source [s] airs on local [day] (0 for a normal source).
int perDayOn(Source s, DateTime day) => s.perDay?[day.weekday - 1] ?? 0;

final _rareEpoch = DateTime.utc(2000, 1, 3); // a Monday

/// [channel]'s rare-source blocks for local [day], from [pool] (entries tagged with their source).
/// No stored state: each rare source's entries are shuffled once (seed channel|source) and the day
/// takes the next `perDay` of that loop, counted from a fixed epoch, so nothing repeats until the
/// whole source has aired (while the pool stays the same). Start time, seeded by channel|source|date,
/// on the half hour: one entry 09:00-22:00, 2+ entries (a marathon) 11:00-13:00, always moved
/// earlier so the block ends by midnight. [spares] extra picks stand in for blocked ones.
List<SerialBlock> rareBlocks(Channel channel, List<Entry> pool, DateTime day, {int spares = 3}) {
  final out = <SerialBlock>[];
  for (final (k, s) in channel.sources.indexed) {
    final n = perDayOn(s, day);
    final eps = [for (final e in pool) if (e.source == k && isRare(channel, e)) e]..sort((a, b) => a.id.compareTo(b.id));
    if (n == 0 || eps.isEmpty) continue;
    final days = DateTime.utc(day.year, day.month, day.day).difference(_rareEpoch).inDays;
    var first = days ~/ 7 * s.perDay!.fold<int>(0, (a, b) => a + b);
    for (var i = 0; i < days % 7; i++) {
      first += s.perDay![i];
    }
    final perm = seededShuffle(eps, stableHash('ch${channel.number}|rare$k'));
    final picks = [for (var i = 0; i < n + spares && i < eps.length; i++) perm[(first + i) % eps.length]];
    final count = n < picks.length ? n : picks.length;
    final minutes = (picks.take(count).fold(0.0, (a, e) => a + e.durationSeconds) / 60).ceil();
    final hi = min((count > 1 ? 13 : 22) * 60, 24 * 60 - minutes);
    final lo = min((count > 1 ? 11 : 9) * 60, hi);
    final rng = SeededRandom(stableHash('ch${channel.number}|rare$k|${dayKey(day)}'));
    final start = lo + rng.nextInt((hi - lo) ~/ 30 + 1) * 30;
    // ponytail: blocks of several rare sources (or a rare block and prime-time serials) may overlap;
    // layoutSerialDay pushes the later one back and drops what would pass midnight.
    out.add(SerialBlock(start < 0 ? 0 : start, minutes, count, picks));
  }
  return out;
}

/// [channel]'s themed time blocks for local [day] (see [TimeBlock]). No stored state: the referenced
/// sources' entries in [pool] (tagged with their source; untagged pools from before give nothing) are
/// shuffled by channel|block|date and whole entries are taken until the window is full; the last may
/// run past the window's end, never past midnight or into a later block. A source too small just fills
/// what it can and the shuffle does the rest. [taken] (the day's serial and rare blocks) win: the window
/// is trimmed around them (one inside the window cuts the window's tail) and their entries are not
/// picked. [spares] extra picks stand in for blocked ones. The picks leave the day's shuffle (see [layoutSerialDay]).
List<SerialBlock> themedBlocks(Channel channel, List<Entry> pool, DateTime day,
    {List<SerialBlock> taken = const [], int spares = 3}) {
  final out = <SerialBlock>[];
  final used = {for (final b in taken) for (final e in b.episodes) e.id};
  final others = [...taken]..sort((a, b) => a.startMinute - b.startMinute);
  for (final (k, tb) in channel.timeBlocks.indexed) {
    if (!tb.days[day.weekday - 1]) continue;
    var start = tb.startMinute, end = tb.endMinute;
    for (final b in others) {
      final bEnd = b.startMinute + b.minutes;
      if (b.startMinute >= end || bEnd <= start) continue;
      if (b.startMinute <= start) {
        start = bEnd;
      } else {
        end = b.startMinute;
      }
    }
    if (start >= end) continue;
    final eps = [
      for (final e in pool)
        if (tb.sources.contains(e.source) && e.durationSeconds >= tb.minMinutes * 60 && !isRare(channel, e) && !used.contains(e.id)) e
    ]..sort((a, b) => a.id.compareTo(b.id));
    var limit = 24 * 60; // the last pick may run past [end], but not into the next block
    for (final b in others) {
      if (b.startMinute >= end && b.startMinute < limit) limit = b.startMinute;
    }
    final picks = <Entry>[];
    var count = 0, total = 0.0;
    for (final e in seededShuffle(eps, stableHash('ch${channel.number}|block$k|${dayKey(day)}'))) {
      if (total >= (end - start) * 60) {
        if (picks.length - count >= spares) break;
        picks.add(e); // a spare
      } else if (start * 60 + total + e.durationSeconds <= limit * 60) {
        picks.add(e);
        count++;
        total += e.durationSeconds;
      }
    }
    if (count == 0) continue;
    used.addAll(picks.map((e) => e.id));
    out.add(SerialBlock(start, end - start, count, picks));
  }
  return out;
}

/// All of a day's blocks: serials ([episodes], see `buildSerialEpisodes`), rare sources, then themed
/// time blocks fitted around them.
List<SerialBlock> dayBlocks(Channel channel, List<List<List<Entry>>> episodes, List<Entry> pool, DateTime day) {
  final fixed = [...serialBlocks(channel, episodes, day), ...rareBlocks(channel, pool, day)];
  return [...fixed, ...themedBlocks(channel, pool, day, taken: fixed)];
}

/// The themed block label for slot [s] of [c] ("Saturday Morning Cartoons"): its entry is from a
/// block's source, at least its `minMinutes` long, airs whole (picks are never cut; shuffle filler cut
/// at midnight or at a block can be) and starts inside that block's window on that weekday. Null
/// otherwise. A whole-fitting source entry in the window is a pick: the pick loop takes every one that fits.
String? themeLabelOf(Channel c, Slot s) {
  final src = s.entry.source;
  if (src == null) return null;
  final m = s.start.hour * 60 + s.start.minute;
  for (final b in c.timeBlocks) {
    if (b.days[s.start.weekday - 1] &&
        b.sources.contains(src) &&
        s.entry.durationSeconds >= b.minMinutes * 60 &&
        s.end.difference(s.start) >= _len(s.entry) &&
        m >= b.startMinute &&
        m < b.endMinute) {
      return b.label;
    }
  }
  return null;
}

Duration _len(Entry e) => Duration(milliseconds: (e.durationSeconds * 1000).round().clamp(1000, 1 << 40));

/// Like [layoutDay] with serial [blocks] placed in the evening. Each block starts at its slot time
/// or, when the block before it ran long, as soon as that ends (pushed back); it airs `count` whole
/// episodes, and the rest of its nominal slot gets items from [order] that fit. An episode that would
/// not end by midnight is dropped (the night stops at midnight). All other time is [order] (without
/// the blocks' episodes), an item that doesn't fit before a block giving way to one that does.
List<Slot> layoutSerialDay(List<Entry> order, DateTime day, List<SerialBlock> blocks) {
  if (blocks.isEmpty) return layoutDay(order, day);
  final end = DateTime(day.year, day.month, day.day + 1);
  final serialIds = {for (final b in blocks) for (final e in b.episodes) e.id}; // also rare-block picks
  final pool = [for (final e in order) if (!serialIds.contains(e.id)) e];
  final queue = <Entry>[];
  final slots = <Slot>[];
  var t = DateTime(day.year, day.month, day.day);

  void fill(DateTime until) {
    while (t.isBefore(until) && pool.isNotEmpty) {
      if (queue.isEmpty) queue.addAll(pool);
      final left = until.difference(t);
      final i = queue.indexWhere((e) => _len(e) <= left);
      final e = queue.removeAt(i < 0 ? 0 : i); // nothing fits: cut the next one at [until]
      var next = t.add(_len(e));
      if (next.isAfter(until)) next = until;
      slots.add(Slot(e, t, next));
      t = next;
    }
    if (t.isBefore(until)) t = until; // empty pool: dead air until the block
  }

  for (final b in [...blocks]..sort((a, b) => a.startMinute - b.startMinute)) {
    final nominal = DateTime(day.year, day.month, day.day, 0, b.startMinute);
    if (!t.isBefore(end)) break;
    fill(nominal);
    for (final e in b.episodes.take(b.count)) {
      final next = t.add(_len(e));
      if (next.isAfter(end)) break; // would run past midnight
      slots.add(Slot(e, t, next));
      t = next;
    }
    fill(nominal.add(Duration(minutes: b.minutes)));
  }
  fill(end);
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
