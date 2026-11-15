import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

import 'pool_builder_test.dart' show FakeApi;
import 'rare_blocks_test.dart' show entry;
import 'time_blocks_test.dart' show funnies, pool, saturday;

/// Every slot of [slots] as "id@start-end" (local), for exact comparisons.
String fp(List<Slot> slots) => [for (final s in slots) '${s.entry.id}@${s.start.toIso8601String()}-${s.end.toIso8601String()}'].join('|');

List<Slot> themedDay(DateTime d, {bool Function(Entry)? rated, RatedWindow? window}) =>
    layoutSerialDay(dayOrder(pool, 'ch2', d), d, themedBlocks(funnies, pool, d), rated: rated, window: window);

const night = RatedWindow(22 * 60, 5 * 60);
bool ratedId(Entry e) => e.itemId.startsWith('r');
int minuteOf(DateTime t) => t.hour * 60 + t.minute;

/// Rated slots that start or end outside 22:00-05:00 (the last slot of a day may be cut at midnight).
List<Slot> outOfWindow(List<Slot> day) => [
      for (final s in day)
        if (ratedId(s.entry) && !night.allows(s.start, Duration(milliseconds: (s.entry.durationSeconds * 1000).round()))) s
    ];

/// The day covers 00:00-24:00 with no gap.
void expectNoGaps(List<Slot> day, DateTime d) {
  expect(day.first.start, DateTime(d.year, d.month, d.day));
  expect(day.last.end, DateTime(d.year, d.month, d.day + 1));
  for (var i = 1; i < day.length; i++) {
    expect(day[i].start, day[i - 1].end, reason: 'gap before slot $i');
  }
}

void main() {
  group('golden: no rated entries = the schedule from before rated dayparting', () {
    // Captured from the scheduler before the rated feature (master b0d1f7c).
    final plain = [for (var i = 0; i < 50; i++) entry('p$i', 17 + i % 7 * 9)];
    final d = DateTime(2026, 11, 12);
    test('plain shuffle day and themed-block day unchanged', () {
      expect(stableHash(fp(layoutSerialDay(dayOrder(plain, 'ch9', d), d, const []))), 4070288721);
      expect(stableHash(fp(themedDay(saturday))), 154676380);
    });
    test('passing the rated test and window changes nothing when no entry is rated', () {
      expect(stableHash(fp(layoutSerialDay(dayOrder(plain, 'ch9', d), d, const [], rated: ratedId, window: night))), 4070288721);
      expect(stableHash(fp(themedDay(saturday, rated: ratedId, window: night))), 154676380);
    });
  });

  test('window: starts inside and ends by the end, wrapping past midnight', () {
    DateTime at(int h, int m) => DateTime(2026, 11, 12, h, m);
    const h1 = Duration(hours: 1);
    expect(night.allows(at(22, 0), h1), isTrue);
    expect(night.allows(at(21, 59), h1), isFalse);
    expect(night.allows(at(21, 30), const Duration(hours: 2)), isFalse); // starts before 22:00
    expect(night.allows(at(23, 0), const Duration(hours: 4)), isTrue); // ends 03:00 next morning
    expect(night.allows(at(23, 0), const Duration(hours: 7)), isFalse); // ends 06:00
    expect(night.allows(at(0, 0), h1), isTrue);
    expect(night.allows(at(4, 0), h1), isTrue); // ends exactly 05:00
    expect(night.allows(at(4, 30), h1), isFalse);
    expect(night.allows(at(5, 0), Duration.zero), isFalse);
    expect(night.allows(at(12, 0), h1), isFalse);
    expect(night.contains(at(23, 59)), isTrue);
    expect(night.contains(at(13, 0)), isFalse);
    const evening = RatedWindow(20 * 60, 23 * 60);
    expect(evening.allows(at(20, 0), h1), isTrue);
    expect(evening.allows(at(22, 30), h1), isFalse);
    expect(evening.allows(at(1, 0), h1), isFalse);
    expect(RatedWindow.always.allows(at(12, 0), const Duration(hours: 30)), isTrue);
  });

  group('config', () {
    String cfg(String extra, {String source = '{"query":"a"}'}) =>
        '{"channels":[{"number":2,"name":"F","sources":[$source]$extra},{"number":3,"name":"G","sources":[{"query":"b"}]}]}';
    test('rated.json, per-channel ratedWindow (absent / object / null) and source rated', () {
      final c = parseChannelConfig(cfg(',"ratedWindow":{"start":"21:00","end":"04:30"}', source: '{"query":"a","rated":"R"}'),
          ratedText: '{"window":{"start":"23:00","end":"06:00"},"identifiers":{"robocop-1987":"RoboCop (1987) R"},'
              '"titlePatterns":["\\\\bunrated\\\\b"]}');
      expect(c.rated.window.startMinute, 23 * 60);
      expect(c.rated.window.endMinute, 6 * 60);
      expect(c.rated.identifiers, {'robocop-1987'});
      expect(c.rated.titlePatterns.single.hasMatch('Puppet Master (UNRATED)'), isTrue);
      expect(c.channels[0].sources.single.rated, 'R');
      expect((c.channels[0].ratedWindow!.startMinute, c.channels[0].ratedWindow!.endMinute), (21 * 60, 4 * 60 + 30));
      expect(c.channels[1].ratedWindow, isNull);
      expect(ratedWindowOf(c.channels[1], c), same(c.rated.window));
      expect(parseChannelConfig(cfg(',"ratedWindow":null')).channels[0].ratedWindow!.unrestricted, isTrue);
      expect(parseRatedRules('{"identifiers":["a","b"]}').identifiers, {'a', 'b'});
    });
    test('defaults: no rated.json = empty list, window 22:00-05:00', () {
      final c = parseChannelConfig(cfg(''));
      expect((c.rated.window.startMinute, c.rated.window.endMinute), (22 * 60, 5 * 60));
      expect(c.rated.identifiers, isEmpty);
    });
    test('bad values are ConfigExceptions', () {
      for (final bad in ['nope', '[]', '{"window":{"start":"25:00","end":"05:00"}}', '{"titlePatterns":["("]}', '{"identifiers":3}']) {
        expect(() => parseChannelConfig(cfg(''), ratedText: bad), throwsA(isA<ConfigException>()), reason: bad);
      }
      expect(() => parseChannelConfig(cfg(',"ratedWindow":"late"')), throwsA(isA<ConfigException>()));
    });
  });

  test('ratedTest: metadata flag, tagged rated source, ids (item or entry) and title patterns', () {
    final c = Channel(number: 2, name: 'F', sources: [const Source(query: 'a'), const Source(query: 'b', rated: 'R')]);
    final config = ChannelConfig(
        yearRange: const YearRange(1980, 2010),
        fallbackStart: 1960,
        minContentSeconds: 7200,
        channels: [c],
        rated: RatedRules(identifiers: {'item-x', 'item-y/f.mp4'}, titlePatterns: [RegExp(r'\bunrated\b', caseSensitive: false)]));
    final test = ratedTest(c, config);
    Entry e(String id, {String? title, int? source, String? rated}) => Entry(
        id: '$id/f.mp4', itemId: id, file: 'f.mp4', title: title ?? id, durationSeconds: 60, url: 'u', source: source, rated: rated);
    expect(test(e('plain')), isFalse);
    expect(test(e('meta', rated: 'R')), isTrue);
    expect(test(e('src', source: 1)), isTrue);
    expect(test(e('src0', source: 0)), isFalse);
    expect(test(e('item-x')), isTrue);
    expect(test(e('item-y')), isTrue); // entry id
    expect(test(e('t', title: 'Slumber Party Massacre III UNRATED')), isTrue);
  });

  test('Archive rating metadata: R or harsher', () {
    for (final r in ['R', 'R;L', 'R; Adult Situations; Language', 'NC-17', 'X', 'TV-MA', ' r ']) {
      expect(isAdultRating(r), isTrue, reason: r);
    }
    for (final r in [null, '', 'TV-G', 'PG-13', 'PG', '10', 'Interesting', 'TV-14', 'Rated G']) {
      expect(isAdultRating(r), isFalse, reason: r);
    }
    final meta = ItemMeta('robo', rating: 'R', files: const [ArchiveFile('robo.mp4', format: 'h.264', length: 6000)]);
    expect(pickEntries(meta).single.rated, 'R');
    expect(Entry.fromJson(pickEntries(meta).single.toJson()).rated, 'R');
    expect(pickEntries(ItemMeta('kids', rating: 'TV-G', files: const [ArchiveFile('k.mp4', format: 'h.264', length: 600)])).single.rated, isNull);
  });

  group('scheduler', () {
    final unrated = [for (var i = 0; i < 40; i++) entry('u$i', 25 + i % 4 * 15)];
    final films = [for (var i = 0; i < 20; i++) entry('r$i', 85 + i % 3 * 10)];
    final mixed = [...unrated, ...films];
    List<Slot> dayOf(List<Entry> p, DateTime d, {List<SerialBlock> blocks = const []}) =>
        layoutSerialDay(dayOrder(p, 'ch13', d), d, blocks, rated: ratedId, window: night);

    test('rated entries only start (and end) inside 22:00-05:00, over two weeks', () {
      var nightRated = 0;
      for (var i = 0; i < 14; i++) {
        final d = DateTime(2026, 11, 12 + i);
        final day = dayOf(mixed, d);
        expect(outOfWindow(day), isEmpty, reason: '$d');
        expectNoGaps(day, d);
        nightRated += day.where((s) => ratedId(s.entry)).length;
      }
      expect(nightRated, greaterThan(14)); // eligible at night (several a night), not banned
    });

    test('deterministic: same day = same schedule, whatever order the pool came in', () {
      final d = DateTime(2026, 11, 20);
      expect(fp(dayOf(mixed, d)), fp(dayOf(mixed.reversed.toList(), d)));
      expect(fp(dayOf(mixed, d)), isNot(fp(dayOf(mixed, DateTime(2026, 11, 21)))));
    });

    test('thin unrated part repeats through the day; rated still waits for the night', () {
      final thin = [entry('u0', 30), entry('u1', 40), ...films];
      final d = DateTime(2026, 11, 13);
      final day = dayOf(thin, d);
      expect(outOfWindow(day), isEmpty);
      expectNoGaps(day, d);
      expect(day.where((s) => s.start.hour >= 5 && s.start.hour < 22).every((s) => !ratedId(s.entry)), isTrue);
    });

    test('only rated entries: they air in the daytime rather than dead air', () {
      final d = DateTime(2026, 11, 13);
      final day = dayOf(films, d);
      expectNoGaps(day, d);
      expect(day.any((s) => s.start.hour == 12), isTrue);
    });

    test('window off (null in channels.json): rated entries air any time, same as before', () {
      final d = DateTime(2026, 11, 13);
      final free = layoutSerialDay(dayOrder(mixed, 'ch13', d), d, const [], rated: ratedId, window: RatedWindow.always);
      expect(fp(free), fp(layoutDay(dayOrder(mixed, 'ch13', d), d)));
    });

    test('block episodes: rated ones are skipped in the daytime, spares stand in, the block keeps the rest', () {
      final d = DateTime(2026, 11, 13);
      final block = SerialBlock(13 * 60, 120, 2, [films[0], unrated[0], films[1], unrated[1], unrated[2]]);
      final day = dayOf(mixed, d, blocks: [block]);
      expect(outOfWindow(day), isEmpty);
      final at13 = day.firstWhere((s) => minuteOf(s.start) == 13 * 60);
      expect(at13.entry.id, unrated[0].id);
      expect(day[day.indexOf(at13) + 1].entry.id, unrated[1].id);
      // at 22:00 the same block airs its rated episodes
      final late = dayOf(mixed, d, blocks: [SerialBlock(22 * 60, 120, 2, [films[0], unrated[0], films[1]])]);
      expect(late.firstWhere((s) => minuteOf(s.start) == 22 * 60).entry.id, films[0].id);
    });

    test('themed time block whose sources are rated in the daytime: picks skipped, nothing rated by day', () {
      bool toonsRated(Entry e) => e.source == 1; // the block's HB source as if flagged "rated"
      final day = themedDay(saturday, rated: toonsRated, window: night);
      expect([for (final s in day) if (toonsRated(s.entry) && s.start.hour >= 5 && s.start.hour < 22) s], isEmpty);
      expect(day.any((s) => s.entry.source == 2 && s.start.hour >= 7 && s.start.hour < 12), isTrue); // Looney picks stay
      expectNoGaps(day, saturday);
    });
  });

  test('pool load: rated.json applies to saved pools and days made before it (no rebuild)', () {
    final dir = Directory.systemTemp.createTempSync('rated');
    addTearDown(() => dir.deleteSync(recursive: true));
    final d = DateTime(2026, 11, 14);
    final old = [for (var i = 0; i < 40; i++) entry('u$i', 30), for (var i = 0; i < 20; i++) entry('film$i', 95)];
    final store = SnapshotStore(dir);
    final before = store.day(5, d, old); // saved with no rated list
    expect(before.any((s) => s.entry.itemId.startsWith('film') && s.start.hour >= 5 && s.start.hour < 22), isTrue);
    final c = Channel(number: 5, name: 'Drive-In', sources: [const Source(query: 'a')]);
    final config = parseChannelConfig('{"channels":[{"number":5,"name":"Drive-In","sources":[{"query":"a"}]}]}',
        ratedText: '{"titlePatterns":["^Title film"]}');
    final after = SnapshotStore(dir).day(5, d, old, rated: ratedTest(c, config), window: ratedWindowOf(c, config));
    expect([for (final s in after) if (s.entry.itemId.startsWith('film') && s.start.hour >= 5 && s.start.hour < 22) s], isEmpty);
    expect(after.any((s) => s.entry.itemId.startsWith('film')), isTrue);
  });

  test('buildPool tags entries of a "rated" source with its index, so ratedTest sees them', () async {
    final config = ChannelConfig(yearRange: const YearRange(1980, 2010), fallbackStart: 1960, minContentSeconds: 0, channels: const []);
    final c = Channel(number: 11, name: 'Haunt', sources: [const Source(query: 'q', rated: 'R')]);
    final built = await buildPool(c, config, FakeApi({'a': (1990, 200), 'b': (1995, 210)}));
    expect(built.map((e) => e.source), [0, 0]);
    expect(built.every(ratedTest(c, config)), isTrue);
  });

  test('adult priority: inside the window rated entries air first, unrated fill the rest', () {
    final unrated = [for (var i = 0; i < 40; i++) entry('p$i', 25)];
    final films = [for (var i = 0; i < 6; i++) entry('r$i', 50)];
    final d = DateTime(2026, 11, 12);
    final day = layoutSerialDay(dayOrder([...unrated, ...films], 'ch13', d), d, const [], rated: ratedId, window: night);
    final inWindow = [for (final s in day) if (night.allows(s.start, Duration.zero) || minuteOf(s.start) >= 22 * 60) s];
    // The six films (300 min) fill the 22:00-05:00 window from its start before any unrated item airs there.
    final tonight = [for (final s in day) if (minuteOf(s.start) >= 22 * 60) s];
    expect(tonight.take(2).every((s) => ratedId(s.entry)), isTrue);
    expect(inWindow, isNotEmpty);
    expect(outOfWindow(day), isEmpty);
    expectNoGaps(day, d);
  });
}
