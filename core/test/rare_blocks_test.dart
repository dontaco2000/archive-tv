import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

import 'pool_builder_test.dart' show FakeApi;

Entry entry(String id, int minutes, {int? source}) => Entry(
      id: '$id/f.mp4',
      itemId: id,
      file: 'f.mp4',
      title: 'Title $id',
      durationSeconds: minutes * 60.0,
      url: 'u',
      source: source,
    );

const week = [1, 1, 1, 1, 1, 1, 3]; // Monday first: {"default": 1, "sun": 3}
final channel = Channel(number: 46, name: 'Pickup', sources: [
  const Source(query: 'trucks'),
  const Source(query: 'nascar', perDay: week, blockLabel: 'NASCAR'),
]);
final races = [for (var i = 0; i < 40; i++) entry('race$i', 200 + i % 4 * 10, source: 1)];
final other = [for (var i = 0; i < 60; i++) entry('truck$i', 30 + i % 3 * 15)];
final pool = [...other, ...races];

final sunday = DateTime(2026, 11, 15);
final monday = DateTime(2026, 11, 16);

List<Slot> dayOf(DateTime d) =>
    layoutSerialDay(dayOrder([for (final e in pool) if (!isRare(channel, e)) e], 'ch46', d), d, rareBlocks(channel, pool, d));

void main() {
  test('config: perDay object, number shorthand, blockLabel; bad day rejected', () {
    String cfg(String src) => '{"channels":[{"number":46,"name":"P","sources":[$src]}]}';
    final s = parseChannelConfig(cfg('{"query":"q","perDay":{"default":1,"sun":3},"blockLabel":"NASCAR"}')).channels.single.sources.single;
    expect(s.perDay, week);
    expect(s.blockLabel, 'NASCAR');
    expect(parseChannelConfig(cfg('{"query":"q","perDay":{"sat":2}}')).channels.single.sources.single.perDay, [0, 0, 0, 0, 0, 2, 0]);
    expect(parseChannelConfig(cfg('{"query":"q","perDay":2}')).channels.single.sources.single.perDay, List.filled(7, 2));
    expect(parseChannelConfig(cfg('{"query":"q"}')).channels.single.sources.single.perDay, isNull);
    expect(() => parseChannelConfig(cfg('{"query":"q","perDay":{"sunday":3}}')), throwsA(isA<ConfigException>()));
    expect(() => parseChannelConfig(cfg('{"query":"q","perDay":-1}')), throwsA(isA<ConfigException>()));
  });

  test('weekday mapping uses the local date: Sunday 3, Monday-Saturday 1', () {
    final s = channel.sources[1];
    expect(perDayOn(s, sunday), 3);
    expect(perDayOn(s, DateTime(2026, 11, 15, 23, 59)), 3);
    expect(perDayOn(s, monday), 1);
    for (var d = 16; d < 22; d++) {
      expect(perDayOn(s, DateTime(2026, 11, d)), 1);
    }
    expect(perDayOn(channel.sources[0], sunday), 0);
  });

  test('deterministic: same day, same blocks, whatever the pool order', () {
    String sig(List<SerialBlock> b) => [for (final x in b) '${x.startMinute}:${x.episodes.map((e) => e.id).join(',')}'].join('|');
    expect(sig(rareBlocks(channel, pool, monday)), sig(rareBlocks(channel, pool.reversed.toList(), monday)));
    expect(sig(rareBlocks(channel, pool, monday)), isNot(sig(rareBlocks(channel, pool, DateTime(2026, 11, 17)))));
  });

  test('Sunday: 3 consecutive races starting 11:00-13:00; weekdays: one race 09:00-22:00', () {
    for (var d = 0; d < 56; d++) {
      final day = DateTime(2026, 11, 15 + d);
      final slots = dayOf(day);
      final rare = [for (final (i, s) in slots.indexed) if (isRare(channel, s.entry)) i];
      final sun = day.weekday == DateTime.sunday;
      expect(rare.length, sun ? 3 : 1, reason: '$day');
      final start = slots[rare.first].start;
      expect(start.minute % 30, 0);
      expect(start.hour, inInclusiveRange(sun ? 11 : 9, sun ? 13 : 22));
      if (sun) expect(rare, [rare.first, rare.first + 1, rare.first + 2]); // one block
    }
  });

  test('never runs past midnight; whole entries; no race on two days in a row', () {
    Set<String> prev = {};
    for (var d = 0; d < 120; d++) {
      final day = DateTime(2026, 11, 1 + d);
      final slots = dayOf(day);
      final rare = [for (final s in slots) if (isRare(channel, s.entry)) s];
      for (final s in rare) {
        expect(s.end.difference(s.start).inSeconds, s.entry.durationSeconds.round()); // not cut
        expect(s.end.isAfter(DateTime(day.year, day.month, day.day + 1)), isFalse);
      }
      final ids = {for (final s in rare) s.entry.id};
      expect(ids.intersection(prev), isEmpty, reason: '$day');
      prev = ids;
      expect(slots.last.end, DateTime(day.year, day.month, day.day + 1));
    }
  });

  test('a long marathon is moved earlier so it still ends by midnight', () {
    final long = Channel(number: 9, name: 'L', sources: [
      const Source(query: 'x'),
      const Source(query: 'y', perDay: [4, 4, 4, 4, 4, 4, 4]),
    ]);
    final p = [...other, for (var i = 0; i < 10; i++) entry('long$i', 240, source: 1)]; // 16 h a day
    for (var d = 0; d < 20; d++) {
      final b = rareBlocks(long, p, DateTime(2026, 11, 1 + d)).single;
      expect(b.startMinute + b.minutes, lessThanOrEqualTo(24 * 60));
    }
  });

  test('rare entries leave the shuffle: only the day\'s picks air', () {
    final slots = dayOf(monday);
    final picks = rareBlocks(channel, pool, monday).single.episodes.take(1).map((e) => e.id).toSet();
    expect({for (final s in slots) if (isRare(channel, s.entry)) s.entry.id}, picks);
    expect(slots.where((s) => !isRare(channel, s.entry)), isNotEmpty);
  });

  test('backward compatible: no perDay -> no rare blocks, untagged entries, same layout', () {
    final plain = Channel(number: 5, name: 'X', sources: [const Source(query: 'a')]);
    expect(rareBlocks(plain, pool, monday), isEmpty);
    expect(isRare(plain, races.first), isFalse); // index 1 is out of range for this channel
    final order = dayOrder(other, 'ch5', monday);
    expect(layoutSerialDay(order, monday, const []).map((s) => s.entry.id), layoutDay(order, monday).map((s) => s.entry.id));
    final e = Entry.fromJson(entry('a', 5).toJson());
    expect(e.source, isNull);
    expect(entry('a', 5, source: 2).toJson()['source'], 2);
    expect(Entry.fromJson(entry('a', 5, source: 2).toJson()).copyWith(title: 't').source, 2);
  });

  test('perDayMinMinutes: shorter entries of a rare source stay in the shuffle', () {
    final c = Channel(number: 46, name: 'P', sources: [
      const Source(query: 't'),
      const Source(query: 'n', perDay: week, perDayMinMinutes: 60),
    ]);
    final clip = entry('clip', 12, source: 1);
    expect(isRare(c, clip), isFalse);
    expect(isRare(c, races.first), isTrue);
    expect(rareBlocks(c, [...pool, clip], monday).single.episodes.contains(clip), isFalse);
    expect(parseChannelConfig('{"channels":[{"number":1,"name":"P","sources":[{"query":"q","perDay":1,"perDayMinMinutes":60}]}]}')
        .channels.single.sources.single.perDayMinMinutes, 60);
  });

  test('buildPool tags only entries of perDay/blockLabel sources', () async {
    final config = ChannelConfig(yearRange: const YearRange(1980, 2010), fallbackStart: 1960, minContentSeconds: 0, channels: const []);
    final api = FakeApi({'a': (1990, 200), 'b': (1995, 210)});
    final rare = Channel(number: 1, name: 'R', sources: [const Source(query: 'q', perDay: week)]);
    expect((await buildPool(rare, config, api)).map((e) => e.source), [0, 0]);
    final plain = Channel(number: 2, name: 'P', sources: [const Source(query: 'q')]);
    expect((await buildPool(plain, config, api)).map((e) => e.source), [null, null]);
  });

  test('guide: a source blockLabel merges different race titles into "NASCAR Marathon"', () {
    final slots = dayOf(sunday);
    final blocks = guideBlocks(slots, labelOf: (e) => blockLabelOf(channel, e));
    final nascar = blocks.where((b) => b.entry.title.startsWith('NASCAR')).toList();
    expect(nascar.length, 1);
    expect(nascar.single.entry.title, 'NASCAR Marathon');
    expect(nascar.single.end.difference(nascar.single.start), greaterThan(const Duration(hours: 9)));
    // without the label, three different titles stay three cells
    expect(guideBlocks(slots).where((b) => b.entry.title.startsWith('Title race')).length, 3);
  });

  test('SnapshotStore inShuffle drops rare entries from a day saved before perDay', () {
    final dir = Directory.systemTemp.createTempSync('rare');
    try {
      final store = SnapshotStore(dir);
      store.day(46, monday, pool); // old-style save: races in the shuffle
      final slots = SnapshotStore(dir).day(46, monday, pool,
          serials: (d) => rareBlocks(channel, pool, d), inShuffle: (e) => !isRare(channel, e));
      expect(slots.where((s) => isRare(channel, s.entry)).length, 1);
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
