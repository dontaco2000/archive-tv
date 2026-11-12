import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

import 'pool_builder_test.dart' show FakeApi;
import 'rare_blocks_test.dart' as rare;
import 'rare_blocks_test.dart' show entry;

const sat = [false, false, false, false, false, true, false];
final funnies = Channel(number: 2, name: 'Funnies', sources: [
  const Source(query: 'edgy'),
  const Source(query: 'hb'),
  const Source(query: 'looney'),
], timeBlocks: [
  TimeBlock(label: 'Saturday Morning Cartoons', days: sat, startMinute: 7 * 60, endMinute: 12 * 60, sources: [1, 2]),
]);
final toons = [
  for (var i = 0; i < 30; i++) entry('hb$i', 7 + i % 3 * 8, source: 1),
  for (var i = 0; i < 30; i++) entry('looney$i', 7, source: 2),
];
final edgy = [for (var i = 0; i < 80; i++) entry('edgy$i', 22)];
final pool = [...edgy, ...toons];
final saturday = DateTime(2026, 11, 14);

List<Slot> dayOf(Channel c, List<Entry> p, DateTime d, {List<SerialBlock> fixed = const []}) =>
    layoutSerialDay(dayOrder(p, 'ch${c.number}', d), d, [...fixed, ...themedBlocks(c, p, d, taken: fixed)]);

String sig(List<SerialBlock> b) => [for (final x in b) '${x.startMinute}/${x.minutes}/${x.count}:${x.episodes.map((e) => e.id).join(',')}'].join('|');

void main() {
  test('config: parsed; bad day, source index, overlap and backwards window rejected', () {
    String cfg(String tb) => '{"channels":[{"number":2,"name":"F","sources":[{"query":"a"},{"query":"b"}],"timeBlocks":[$tb]}]}';
    final b = parseChannelConfig(cfg('{"label":"Cartoons","days":["sat","sun"],"start":"07:00","end":"12:00","sources":[1]}'))
        .channels.single.timeBlocks.single;
    expect((b.label, b.startMinute, b.endMinute), ('Cartoons', 420, 720));
    expect(b.days, [false, false, false, false, false, true, true]);
    expect(b.sources, [1]);
    expect(parseChannelConfig(cfg('{"label":"L","days":["fri"],"start":"20:00","end":"24:00","sources":[0]}')).channels.single.timeBlocks.single.endMinute, 1440);
    for (final bad in [
      '{"label":"L","days":["saturday"],"start":"07:00","end":"12:00","sources":[1]}',
      '{"label":"L","days":["sat"],"start":"07:00","end":"12:00","sources":[2]}',
      '{"label":"L","days":["sat"],"start":"12:00","end":"07:00","sources":[1]}',
      '{"label":"A","days":["sat"],"start":"07:00","end":"12:00","sources":[1]},{"label":"B","days":["sat","sun"],"start":"11:00","end":"13:00","sources":[0]}',
    ]) {
      expect(() => parseChannelConfig(cfg(bad)), throwsA(isA<ConfigException>()), reason: bad);
    }
    // same hours on different days is fine
    expect(parseChannelConfig(cfg('{"label":"A","days":["sat"],"start":"07:00","end":"12:00","sources":[1]},{"label":"B","days":["sun"],"start":"07:00","end":"12:00","sources":[0]}'))
        .channels.single.timeBlocks.length, 2);
  });

  test('deterministic: same day, same picks, whatever the pool order; another Saturday differs', () {
    expect(sig(themedBlocks(funnies, pool, saturday)), sig(themedBlocks(funnies, pool.reversed.toList(), saturday)));
    expect(sig(themedBlocks(funnies, pool, saturday)), isNot(sig(themedBlocks(funnies, pool, DateTime(2026, 11, 21)))));
  });

  test('day of week: only Saturdays (local date) get the block', () {
    for (var d = 0; d < 14; d++) {
      final day = DateTime(2026, 11, 9 + d);
      expect(themedBlocks(funnies, pool, day).length, day.weekday == DateTime.saturday ? 1 : 0, reason: '$day');
    }
  });

  test('window fit: starts 07:00 sharp, whole entries back to back, ends at or just past 12:00', () {
    final slots = dayOf(funnies, pool, saturday);
    final block = [for (final s in slots) if (themeLabelOf(funnies, s) != null) s];
    expect(block.first.start, DateTime(2026, 11, 14, 7));
    for (final s in block) {
      expect(s.end.difference(s.start).inSeconds, s.entry.durationSeconds.round());
      expect(toons.contains(s.entry), isTrue);
    }
    expect(block.last.end.isBefore(DateTime(2026, 11, 14, 12)), isFalse);
    expect(block.last.start.isBefore(DateTime(2026, 11, 14, 12)), isTrue);
    expect(slots.last.end, DateTime(2026, 11, 15)); // rest of the day is the shuffle
  });

  test('no double airing: block picks are not in the rest of the day', () {
    final slots = dayOf(funnies, pool, saturday);
    final ids = [for (final s in slots) s.entry.id];
    final picks = themedBlocks(funnies, pool, saturday).single.episodes.map((e) => e.id);
    for (final id in picks) {
      expect(ids.where((x) => x == id).length, lessThanOrEqualTo(1), reason: id);
    }
  });

  test('never past midnight; small source fills what it can, the shuffle does the rest', () {
    final late = Channel(number: 3, name: 'Haunt', sources: [const Source(query: 'a'), const Source(query: 'b')], timeBlocks: [
      TimeBlock(label: 'Friday Night Creature Feature', days: List.filled(7, true), startMinute: 20 * 60, endMinute: 24 * 60, sources: [1]),
    ]);
    final movies = [for (var i = 0; i < 3; i++) entry('movie$i', 100, source: 1)]; // 5 h of movies for a 4 h window
    final p = [...edgy, ...movies];
    for (var d = 0; d < 10; d++) {
      final day = DateTime(2026, 11, 1 + d);
      final slots = dayOf(late, p, day);
      expect(slots.last.end, DateTime(day.year, day.month, day.day + 1));
      final b = [for (final s in slots) if (themeLabelOf(late, s) != null) s];
      expect(b.length, 2, reason: 'a third 100-min movie from 23:20 would pass midnight');
      expect(b.last.end.isAfter(DateTime(day.year, day.month, day.day + 1)), isFalse);
    }
    final films = Channel(number: 3, name: 'H', sources: late.sources, timeBlocks: [
      TimeBlock(label: 'F', days: List.filled(7, true), startMinute: 20 * 60, endMinute: 24 * 60, sources: [1], minMinutes: 60),
    ]);
    final clip = entry('clip', 10, source: 1);
    expect(themedBlocks(films, [...p, clip], saturday).single.episodes.contains(clip), isFalse);
    expect(parseChannelConfig('{"channels":[{"number":1,"name":"H","sources":[{"query":"q"}],"timeBlocks":[{"label":"F","days":["fri"],"start":"20:00","end":"24:00","sources":[0],"minMinutes":60}]}]}')
        .channels.single.timeBlocks.single.minMinutes, 60);
    final small = Channel(number: 3, name: 'H', sources: late.sources, timeBlocks: late.timeBlocks);
    final one = [...edgy, entry('only', 90, source: 1)];
    final slots = dayOf(small, one, saturday);
    final at = slots.indexWhere((s) => s.entry.id == 'only/f.mp4');
    expect(slots[at].start, DateTime(2026, 11, 14, 20));
    expect(slots[at + 1].entry.id, startsWith('edgy')); // shuffle continues after the short block
  });

  test('serial/rare blocks win: themed window is trimmed, and their entries are never picked', () {
    final serial = SerialBlock(9 * 60, 60, 1, [entry('ep1', 50)]);
    final blocks = themedBlocks(funnies, pool, saturday, taken: [serial]);
    expect((blocks.single.startMinute, blocks.single.minutes), (7 * 60, 120)); // 07:00-09:00, tail cut
    final early = SerialBlock(6 * 60, 120, 1, [toons.first]);
    final b2 = themedBlocks(funnies, pool, saturday, taken: [early]).single;
    expect((b2.startMinute, b2.minutes), (8 * 60, 240)); // pushed to 08:00
    expect(b2.episodes.contains(toons.first), isFalse);
    final slots = dayOf(funnies, pool, saturday, fixed: [serial]);
    final ep = slots.firstWhere((s) => s.entry.id == 'ep1/f.mp4');
    expect(ep.start, DateTime(2026, 11, 14, 9)); // not pushed by the themed block
    expect(toons.contains(slots.firstWhere((s) => s.start == DateTime(2026, 11, 14, 7)).entry), isTrue);
    expect(slots.where((s) => toons.contains(s.entry) && s.start.hour < 9).every((s) => !s.end.isAfter(ep.start)), isTrue);
    expect(themedBlocks(funnies, pool, saturday, taken: [SerialBlock(6 * 60, 7 * 60, 1, [entry('x', 400)])]), isEmpty);
    // a block right after the window (Chuckles: sitcoms 19-21, Soap serial at 21): the last pick must not run into it
    final soap = SerialBlock(12 * 60, 60, 1, [entry('soap1', 25)]);
    final s3 = dayOf(funnies, pool, saturday, fixed: [soap]);
    expect(s3.firstWhere((s) => s.entry.id == 'soap1/f.mp4').start, DateTime(2026, 11, 14, 12));
    expect(s3.where((s) => themeLabelOf(funnies, s) != null).last.end.isAfter(DateTime(2026, 11, 14, 12)), isFalse);
  });

  test('missing tags (pool built before timeBlocks): no block, no crash, plain day', () {
    final untagged = [for (final e in pool) Entry.fromJson({...e.toJson()}..remove('source'))];
    expect(themedBlocks(funnies, untagged, saturday), isEmpty);
    expect(dayOf(funnies, untagged, saturday).map((s) => s.entry.id), layoutDay(dayOrder(untagged, 'ch2', saturday), saturday).map((s) => s.entry.id));
  });

  test('guide: the block is one cell titled with the label; info label only inside the window', () {
    final slots = dayOf(funnies, pool, saturday);
    final cells = guideBlocks(slots, themeOf: (s) => themeLabelOf(funnies, s));
    final themed = cells.where((c) => c.entry.title == 'Saturday Morning Cartoons').toList();
    expect(themed.length, 1);
    expect(themed.single.start, DateTime(2026, 11, 14, 7));
    expect(themed.single.end.difference(themed.single.start).inMinutes, greaterThanOrEqualTo(300));
    final monday = DateTime(2026, 11, 16);
    expect(dayOf(funnies, pool, monday).any((s) => themeLabelOf(funnies, s) != null), isFalse);
  });

  test('buildPool tags entries of sources a time block uses', () async {
    final config = ChannelConfig(yearRange: const YearRange(1980, 2010), fallbackStart: 1960, minContentSeconds: 0, channels: const []);
    final api = FakeApi({'a': (1990, 200), 'b': (1995, 210)});
    final c = Channel(number: 1, name: 'T', sources: [const Source(query: 'q')], timeBlocks: [
      TimeBlock(label: 'L', days: sat, startMinute: 0, endMinute: 60, sources: [0]),
    ]);
    expect((await buildPool(c, config, api)).map((e) => e.source), [0, 0]);
  });

  test('regression: a channel without timeBlocks plans exactly as before (golden hash)', () {
    final b = StringBuffer();
    for (var d = 0; d < 14; d++) {
      final day = DateTime(2026, 11, 9 + d);
      final ch = rare.channel;
      final slots = layoutSerialDay(
          dayOrder([for (final e in rare.pool) if (!isRare(ch, e)) e], 'ch46', day), day, dayBlocks(ch, const [], rare.pool, day));
      for (final s in slots) {
        b.write('${s.entry.id}@${s.start.toIso8601String()}-${s.end.toIso8601String()};');
      }
      for (final s in guideBlocks(slots, labelOf: (e) => blockLabelOf(ch, e), themeOf: (s) => themeLabelOf(ch, s))) {
        b.write('${s.entry.title}@${s.start.toIso8601String()}-${s.end.toIso8601String()};');
      }
    }
    expect((stableHash(b.toString()), b.length), (3610888192, 48567)); // computed before time blocks existed
  });
}
