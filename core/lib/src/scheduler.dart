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

Duration _len(Entry e) => Duration(milliseconds: (e.durationSeconds * 1000).round().clamp(1000, 1 << 40));

/// Like [layoutDay] with serial [blocks] placed in the evening. Each block starts at its slot time
/// or, when the block before it ran long, as soon as that ends (pushed back); it airs `count` whole
/// episodes, and the rest of its nominal slot gets items from [order] that fit. An episode that would
/// not end by midnight is dropped (the night stops at midnight). All other time is [order] (without
/// the blocks' episodes), an item that doesn't fit before a block giving way to one that does.
List<Slot> layoutSerialDay(List<Entry> order, DateTime day, List<SerialBlock> blocks) {
  if (blocks.isEmpty) return layoutDay(order, day);
  final end = DateTime(day.year, day.month, day.day + 1);
  final serialIds = {for (final b in blocks) for (final e in b.episodes) e.id};
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
