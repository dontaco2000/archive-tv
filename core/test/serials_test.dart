import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

/// A tiny example of the serial config (two slots; the first is a queue of two shows).
const _config = '''
{
  "channels": [
    {"number": 3, "name": "Sakura", "sources": [{"query": "subject:anime"}],
     "primeTime": {"start": "18:00", "slots": 6, "slotMinutes": 60},
     "serials": [
       {"start": "22:00", "epoch": "2026-11-12", "shows": [
          {"title": "Death Note", "identifiers": ["death-note-complete-2006-2007"], "episode": "E(\\\\d+)"},
          {"title": "Evangelion", "identifiers": ["entiretyofeva"], "include": "S01E", "episode": "S(\\\\d+)E(\\\\d+)"}
       ]},
       {"start": "23:00", "epoch": "2026-11-12", "perDay": 1, "shows": [
          {"title": "I, Claudius", "identifiers": ["i-claudius-hail-who-ep-10"], "order": ["b.mp4", "a.mp4"]}
       ]}
     ]},
    {"number": 2, "name": "Funnies", "sources": [{"query": "subject:cartoon"}]}
  ]
}
''';

final _quirks = jsonDecode(File('test/fixtures/serial_quirks.json').readAsStringSync()) as Map<String, dynamic>;

ItemMeta _meta(String id, List<String> names, {double length = 22 * 60}) => ItemMeta(id,
    files: [for (final n in names) ArchiveFile(n, format: 'h.264', size: 100000000, length: length)]);

ItemMeta _quirk(String id) => _meta(id, (_quirks[id] as List).cast<String>());

List<String> _titles(List<Entry> l) => [for (final e in l) e.title];

Entry ep(String id, double minutes) => Entry(
    id: id, itemId: id.split('/').first, file: id, title: id, durationSeconds: minutes * 60, url: 'https://x/$id');

List<Entry> show(String name, int n, {double minutes = 23}) => [for (var i = 1; i <= n; i++) ep('$name/$i', minutes)];

Channel channel(List<SerialSlot> serials) => Channel(number: 9, name: 'T', serials: serials);

SerialSlot slot(int hour, {int? perDay, int shows = 1}) => SerialSlot(
    startMinute: hour * 60,
    epoch: DateTime(2026, 11, 12),
    perDay: perDay,
    shows: [for (var i = 0; i < shows; i++) SerialShow(title: 'S$i', identifiers: ['x'])]);

final filler = [for (var i = 0; i < 400; i++) ep('f/${i.toString().padLeft(3, '0')}', 5 + (i % 7) * 4)];
final day0 = DateTime(2026, 11, 12);

DateTime at(int h, [int m = 0, DateTime? d]) => DateTime((d ?? day0).year, (d ?? day0).month, (d ?? day0).day, h, m);

void expectTiles(List<Slot> s, DateTime day) {
  expect(s.first.start, DateTime(day.year, day.month, day.day));
  expect(s.last.end, DateTime(day.year, day.month, day.day + 1));
  for (var i = 1; i < s.length; i++) {
    expect(s[i].start, s[i - 1].end, reason: 'gap/overlap at $i');
  }
}

List<Slot> serialSlots(List<Slot> s) => [for (final x in s) if (!x.entry.id.startsWith('f/')) x];

void main() {
  group('config', () {
    test('parses primeTime and serials; channels without them get defaults', () {
      final c = parseChannelConfig(_config);
      final sakura = c.channel(3)!;
      expect(sakura.primeTime.startMinute, 18 * 60);
      expect(sakura.serials.map((s) => s.startMinute), [22 * 60, 23 * 60]);
      expect(sakura.serials[0].shows.map((s) => s.title), ['Death Note', 'Evangelion']);
      expect(sakura.serials[0].shows[1].include!.hasMatch('x s01e02.mp4'), isTrue); // case-insensitive
      expect(sakura.serials[0].epoch, DateTime(2026, 11, 12));
      expect(sakura.serials[1].perDay, 1);
      expect(sakura.serials[1].shows.single.order, ['b.mp4', 'a.mp4']);
      final funnies = c.channel(2)!;
      expect(funnies.serials, isEmpty);
      expect(funnies.primeTime.slots, 6);
    });

    String withSerials(String serials, [String prime = '']) =>
        '{"channels": [{"number": 3, "name": "S", "sources": [{"query": "q"}]$prime, "serials": $serials}]}';
    void bad(String json, String text) => expect(() => parseChannelConfig(json),
        throwsA(isA<ConfigException>().having((e) => e.message, 'message', contains(text))));

    test('rejects bad serial configs', () {
      const show = '{"title": "A", "identifiers": ["a"]}';
      bad(withSerials('[{"start": "17:00", "epoch": "2026-11-12", "shows": [$show]}]'), 'outside prime time');
      bad(withSerials('[{"start": "18:30", "epoch": "2026-11-12", "shows": [$show]}]', ', "primeTime": {"slots": 1}'),
          'outside prime time');
      bad(withSerials('[{"start": "20:00", "epoch": "2026-11-12", "shows": [$show]}, '
          '{"start": "19:00", "epoch": "2026-11-12", "shows": [$show]}]'), 'overlaps');
      bad(withSerials('[{"shows": [$show]}]'), 'epoch');
      bad(withSerials('[{"epoch": "2026-11-12", "shows": []}]'), 'at least one show');
      bad(withSerials('[{"epoch": "2026-11-12", "shows": [{"title": "A", "identifiers": ["a"], "episode": "E\\\\d+"}]}]'),
          'capture groups');
      bad(withSerials('[{"epoch": "2026-11-12", "shows": [{"title": "A", "identifiers": ["a"], "episode": "("}]}]'),
          'not a valid regex');
      bad(withSerials('[{"epoch": "2026-11-12", "shows": [{"title": "A", "identifiers": ["a"], "order": "x"}]}]'),
          '"order"');
      bad(withSerials('[{"start": "25:00", "epoch": "2026-11-12", "shows": [$show]}]'), 'time like');
    });

    test('slots without start take the prime-time hours in list order', () {
      final c = parseChannelConfig(withSerials(
          '[{"epoch": "2026-11-12", "shows": [{"title": "A", "identifiers": ["a"]}]}, '
          '{"epoch": "2026-11-12", "shows": [{"title": "B", "identifiers": ["b"]}]}]'));
      expect(c.channels.single.serials.map((s) => s.startMinute), [18 * 60, 19 * 60]);
    });
  });

  group('episode resolution (real file-name quirks)', () {
    test('Dragon Ball Z: first number, not "(123)" or the trailing -1; duplicate dropped', () {
      final s = SerialShow(title: 'DBZ', identifiers: ['dbz-westwood-remaster'], episode: RegExp(r'Z - (\d+)'));
      expect(_titles(resolveEpisodes(s, [_quirk('dbz-westwood-remaster')])),
          ['DBZ S1E108', 'DBZ S1E109', 'DBZ S1E110', 'DBZ S1E173']);
    });

    test('Gundam Wing: leading number glued to the title (ep 14 title ends in 01)', () {
      final s = SerialShow(title: 'Gundam Wing', identifiers: ['x'], episode: RegExp(r'^(\d+)'));
      final eps = resolveEpisodes(s, [_quirk('20240812_20240812_2223')]);
      expect(_titles(eps), ['Gundam Wing S1E1', 'Gundam Wing S1E2', 'Gundam Wing S1E10', 'Gundam Wing S1E14']);
      expect(eps.last.file, "14Treize's Fall 01.mp4");
    });

    test('ReBoot: include filter drops the second copy; natural order puts E2 before E10', () {
      final meta = _quirk('reboot-complete-series');
      final natural = resolveEpisodes(SerialShow(title: 'ReBoot', identifiers: ['x'], include: RegExp('^Season ')), [meta]);
      expect([for (final e in natural) e.file], [
        'Season 1/ReBoot S1 E1 The Tearing.mp4',
        'Season 1/ReBoot S1 E2 Racing the Clock.mp4',
        'Season 1/ReBoot S1 E10 Medusa Bug.mp4',
        'Season 2/ReBoot S2 E1 AndrAIa.mp4',
      ]);
      final byNumber = resolveEpisodes(
          SerialShow(title: 'ReBoot', identifiers: ['x'], include: RegExp('^Season '), episode: RegExp(r'S(\d+) E(\d+)')),
          [meta]);
      expect(_titles(byNumber), ['ReBoot S1E1', 'ReBoot S1E2', 'ReBoot S1E10', 'ReBoot S2E1']);
    });

    test('Pokemon: the 8.3 name _AA531~1 does not match the episode regex and is left out', () {
      final s = SerialShow(title: 'Pokemon', identifiers: ['x'], episode: RegExp(r'S(\d+)E(\d+)'));
      expect(_titles(resolveEpisodes(s, [_quirk('pokemon-indigo-league-season-1-1998')])),
          ['Pokemon S1E1', 'Pokemon S1E37', 'Pokemon S1E39']);
    });

    test('I, Claudius: alphabetical names, explicit order list (exclude also applies)', () {
      final s = SerialShow(title: 'I, Claudius', identifiers: ['x'], exclude: RegExp('Old King'), order: [
        'I, Claudius A Touch of Murder Ep1.mp4',
        'I, Claudius Family Affairs Ep2.mp4',
        'i-claudius-hail-who-ep-10/I, Claudius A God in Colchester Ep12.mp4', // by id works too
        'I, Claudius Old King Log Ep13.mp4', // excluded -> skipped
        'missing.mp4',
      ]);
      final eps = resolveEpisodes(s, [_quirk('i-claudius-hail-who-ep-10')]);
      expect([for (final e in eps) e.file.split(' ').last], ['Ep1.mp4', 'Ep2.mp4', 'Ep12.mp4']);
      expect(eps.first.title, 'I, Claudius S1E1');
    });

    test('several items: season from item position; missing items skipped', () {
      final s = SerialShow(title: 'Poldark', identifiers: ['p1', 'gone', 'p2'], episode: RegExp(r'E(\d+)'));
      final eps = resolveEpisodes(s, [
        _meta('p1', ['E2.mp4', 'E1.mp4']),
        null,
        _meta('p2', ['E1.mp4']),
      ]);
      expect(_titles(eps), ['Poldark S1E1', 'Poldark S1E2', 'Poldark S3E1']);
    });

    test('buildSerialEpisodes fetches items and gates shows under 8 episodes', () async {
      final api = _Api({
        'big': _meta('big', [for (var i = 1; i <= 9; i++) 'E$i.mp4']),
        'small': _meta('small', [for (var i = 1; i <= 7; i++) 'E$i.mp4']),
      });
      final c = channel([
        SerialSlot(startMinute: 18 * 60, epoch: day0, shows: [
          SerialShow(title: 'Big', identifiers: ['big'], episode: RegExp(r'E(\d+)')),
          SerialShow(title: 'Small', identifiers: ['small', 'broken']),
        ]),
      ]);
      final logs = <String>[];
      final built = await buildSerialEpisodes(c, api, log: logs.add);
      expect(built.single.map((s) => s.length), [9, 0]);
      expect(logs.join('\n'), allOf(contains('skip broken'), contains('Small has 7 playable episodes')));
    });
  });

  group('scheduling', () {
    test('determinism: same date gives the same plan; days advance by perDay', () {
      final c = channel([slot(18)]);
      final eps = [[show('a', 10)]];
      final p1 = layoutSerialDay(dayOrder(filler, 'ch9', day0), day0, serialBlocks(c, eps, day0));
      final p2 = layoutSerialDay(dayOrder(filler, 'ch9', day0), day0, serialBlocks(c, eps, day0));
      expect([for (final s in p1) '${s.entry.id}@${s.start}'], [for (final s in p2) '${s.entry.id}@${s.start}']);
      expectTiles(p1, day0);

      List<String> night(DateTime d) =>
          [for (final s in serialSlots(layoutSerialDay(dayOrder(filler, 'ch9', d), d, serialBlocks(c, eps, d)))) s.entry.id];
      expect(night(day0), ['a/1', 'a/2']); // 23-min episodes: 2 per hour
      expect(night(DateTime(2026, 11, 13)), ['a/3', 'a/4']);
      expect(night(DateTime(2026, 11, 16)), ['a/9', 'a/10']);
      expect(night(DateTime(2026, 11, 17)), ['a/1', 'a/2']); // loops
      expect(night(DateTime(2026, 11, 11)), ['a/9', 'a/10']); // before the epoch counts backwards
    });

    test('a block starts on the hour; leftover minutes get filler that fits; serial episodes leave the shuffle', () {
      final c = channel([slot(18)]);
      final eps = [[show('a', 10)]];
      final withSerialInPool = [...filler, ...eps[0][0]];
      final s = layoutSerialDay(dayOrder(withSerialInPool, 'ch9', day0), day0, serialBlocks(c, eps, day0));
      expectTiles(s, day0);
      final a1 = s.indexWhere((x) => x.entry.id == 'a/1');
      expect(s[a1].start, at(18));
      expect(s[a1 + 1].entry.id, 'a/2');
      expect(s[a1 + 2].start, at(18, 46));
      final fillerAfter = [for (final x in s) if (!x.start.isBefore(at(18, 46)) && x.start.isBefore(at(19))) x];
      expect(fillerAfter, isNotEmpty);
      expect(fillerAfter.every((x) => x.entry.id.startsWith('f/')), isTrue);
      expect(
          fillerAfter.take(fillerAfter.length - 1).every((x) => x.end.difference(x.start).inSeconds == x.entry.durationSeconds),
          isTrue,
          reason: 'whole items while one fits; only a last sliver may be cut');
      expect(fillerAfter.last.end, at(19));
      // the day's picks (and spares) never air in the shuffle; the engine drops all serial episodes from the pool
      expect(s.where((x) => ['a/1', 'a/2', 'a/3', 'a/4', 'a/5'].contains(x.entry.id)).map((x) => x.entry.id), ['a/1', 'a/2']);
      expect(s.where((x) => x.end.isAfter(at(17, 30)) && x.start.isBefore(at(18))).last.end, at(18),
          reason: 'shuffle gives way at the block start');
    });

    test('queue: after the last episode of a show comes the next show, then it loops to the first', () {
      final c = channel([slot(22, shows: 3)]);
      final eps = [
        [show('dn', 3), show('eva', 2), show('lain', 1)],
      ];
      List<String> night(int i) {
        final d = DateTime(2026, 11, 12 + i);
        return [for (final b in serialBlocks(c, eps, d)) ...b.episodes.take(b.count).map((e) => e.id)];
      }

      expect([for (var i = 0; i < 4; i++) night(i)], [
        ['dn/1', 'dn/2'],
        ['dn/3', 'eva/1'],
        ['eva/2', 'lain/1'],
        ['dn/1', 'dn/2'],
      ]);
    });

    test('overrun pushes the next block back; the slot after recovers its hour', () {
      final c = channel([slot(18, perDay: 1), slot(19), slot(21)]);
      final eps = [
        [show('long', 8, minutes: 100)],
        [show('b', 8)],
        [show('c', 8)],
      ];
      final s = layoutSerialDay(dayOrder(filler, 'ch9', day0), day0, serialBlocks(c, eps, day0));
      expectTiles(s, day0);
      final serial = serialSlots(s);
      expect([for (final x in serial) '${x.entry.id} ${x.start.hour}:${x.start.minute}'],
          ['long/1 18:0', 'b/1 19:40', 'b/2 20:3', 'c/1 21:0', 'c/2 21:23']);
    });

    test('midnight: an episode that would not end by midnight is dropped back to the shuffle', () {
      final c = channel([slot(22, perDay: 1), slot(23)]);
      final eps = [
        [show('long', 8, minutes: 100)], // 22:00-23:40
        [show('b', 8)], // pushed to 23:40: b/1 would end 00:03
      ];
      final s = layoutSerialDay(dayOrder(filler, 'ch9', day0), day0, serialBlocks(c, eps, day0));
      expectTiles(s, day0);
      expect(serialSlots(s).map((x) => x.entry.id), ['long/1']);
      expect(s.last.end, DateTime(2026, 11, 13));
    });

    test('a broken episode (blocklisted) is skipped for the day: the block takes the next one', () {
      final c = channel([slot(18)]);
      final eps = [[show('a', 10)]];
      final dir = Directory.systemTemp.createTempSync('serialsnap');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = SnapshotStore(dir);
      final bad = Blocklist.session()..add('a/1');
      final s = store.day(9, day0, filler, blocklist: bad, serials: (d) => serialBlocks(c, eps, d));
      expectTiles(s, day0);
      expect(serialSlots(s).map((x) => x.entry.id), ['a/2', 'a/3']);
      expect(serialSlots(s).first.start, at(18));
      // the next day is still date-based
      final next = store.day(9, DateTime(2026, 11, 13), filler, blocklist: bad, serials: (d) => serialBlocks(c, eps, d));
      expect(serialSlots(next).map((x) => x.entry.id), ['a/3', 'a/4']);
    });

    test('channels without serials lay out exactly as before', () {
      expect([for (final s in layoutSerialDay(filler, day0, const [])) '${s.entry.id}${s.start}'],
          [for (final s in layoutDay(filler, day0)) '${s.entry.id}${s.start}']);
    });
  });

  group('persistence', () {
    test('day snapshots save the serial picks and keep them when the episode lists change', () {
      final c = channel([slot(18)]);
      final dir = Directory.systemTemp.createTempSync('serialday');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = SnapshotStore(dir).day(9, day0, filler, serials: (d) => serialBlocks(c, [[show('a', 10)]], d));
      final saved = jsonDecode(File('${dir.path}/day-9-2026-11-12.json').readAsStringSync()) as Map;
      expect((saved['serials'] as List).single['count'], 2);
      final again = SnapshotStore(dir).day(9, day0, [], serials: (d) => serialBlocks(c, [[show('zzz', 10)]], d));
      expect([for (final s in again) s.entry.id], [for (final s in first) s.entry.id]);
    });

    test('a day saved before the channel had serials gets them added', () {
      final c = channel([slot(18)]);
      final dir = Directory.systemTemp.createTempSync('serialup');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = SnapshotStore(dir);
      store.ensureWeek(9, day0, filler, days: 1); // old-style day, no serials yet
      expect(serialSlots(store.day(9, day0, filler)), isEmpty);
      final s = store.day(9, day0, filler, serials: (d) => serialBlocks(c, [[show('a', 10)]], d));
      expect(serialSlots(s).map((x) => x.entry.id), ['a/1', 'a/2']);
      expect(serialSlots(SnapshotStore(dir).day(9, day0, [])).length, 2); // saved to disk
    });

    test('PoolStore round-trips serial episode lists; a changed show config invalidates them', () {
      final dir = Directory.systemTemp.createTempSync('serialpool');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = PoolStore(dir);
      final c = channel([slot(18, shows: 2)]);
      expect(store.loadSerials(c), isNull);
      store.saveSerials(c, [
        [show('a', 2), show('b', 1)],
      ]);
      expect(store.loadSerials(c)!.single.map((s) => s.map((e) => e.id).toList()), [
        ['a/1', 'a/2'],
        ['b/1'],
      ]);
      expect(store.loadSerials(channel([slot(18, shows: 3)])), isNull);
      expect(store.loadSerials(channel([slot(20, perDay: 2, shows: 2)])), isNotNull); // timing changes keep the lists
    });
  });
}

class _Api implements ArchiveApi {
  final Map<String, ItemMeta> items;
  _Api(this.items);

  @override
  Future<ItemMeta?> metadata(String identifier) async =>
      items[identifier] ?? (throw ArchiveException('HTTP 404'));

  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async => const [];
}
