import 'dart:math';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Archive stand-in: [items] maps identifier -> (year, minutes of one video).
class FakeApi implements ArchiveApi {
  final Map<String, (int, int)> items;
  final List<String> queries = [];
  final Set<String> failing;
  final String? failQuery; // searches containing this text throw

  final bool slow; // metadata yields so calls overlap
  int inFlight = 0;
  int maxInFlight = 0;

  /// identifier -> language / silent / English sidecar file name.
  final Map<String, ({String? lang, bool silent, bool sub})> tags;

  FakeApi(this.items, {this.failing = const {}, this.failQuery, this.slow = false, this.tags = const {}});

  int metadataCalls = 0;

  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async {
    queries.add(query);
    if (failQuery != null && query.contains(failQuery!)) throw ArchiveException('search down');
    // Honour only the date clause, like the real thing would.
    final m = RegExp(r'date:\[(\d{4})-01-01 TO (\d{4})-12-31\]').firstMatch(query);
    return [
      for (final e in items.entries)
        if (m == null || (e.value.$1 >= int.parse(m.group(1)!) && e.value.$1 <= int.parse(m.group(2)!)))
          ItemSummary(e.key),
    ];
  }

  @override
  Future<ItemMeta?> metadata(String identifier) async {
    inFlight++;
    metadataCalls++;
    maxInFlight = max(maxInFlight, inFlight);
    try {
      if (slow) await Future.delayed(Duration(milliseconds: 5 + identifier.length * 3));
      return _meta(identifier);
    } finally {
      inFlight--;
    }
  }

  ItemMeta? _meta(String identifier) {
    if (failing.contains(identifier)) throw ArchiveException('boom');
    final item = items[identifier];
    if (item == null) return null;
    final t = tags[identifier];
    return ItemMeta(identifier, title: identifier, language: t?.lang, silent: t?.silent ?? false, files: [
      ArchiveFile('$identifier.mp4', format: 'h.264', length: item.$2 * 60.0),
      if (t?.sub ?? false) ArchiveFile('$identifier.en.srt', format: 'SubRip'),
    ]);
  }
}

ChannelConfig config({int minHours = 2, Set<String> exclude = const {}}) => ChannelConfig(
      yearRange: const YearRange(1980, 2010),
      fallbackStart: 1960,
      minContentSeconds: minHours * 3600,
      channels: const [],
      excludeIdentifiers: exclude,
      blockCollections: const ['adultvhs'],
    );

const channel = Channel(number: 5, name: 'Funnies', sources: [Source(query: 'subject:cartoon')]);

void main() {
  test('refilterPool cuts a saved pool to the current excludes and length limits, no copy when all fit', () {
    Entry e(String id, double s) => Entry(id: '$id/f.mp4', itemId: id, file: 'f.mp4', title: id, durationSeconds: s, url: 'u');
    final config = parseChannelConfig('{"excludeIdentifiers": ["x"], "channels": ['
        '{"number": 1, "name": "A", "sources": [{"query": "q", "maxSeconds": 600}, {"query": "r", "maxSeconds": 300}]},'
        '{"number": 2, "name": "B", "sources": [{"query": "q", "maxSeconds": 600}, {"query": "r"}]}]}');
    final pool = [e('x', 200), e('ok', 200), e('long', 700), e('short', 90), e('huge', 30000)];
    expect(refilterPool(config.channels[0], config, pool).map((e) => e.itemId), ['ok']); // max cap 600, min 120
    expect(refilterPool(config.channels[1], config, pool).map((e) => e.itemId), ['ok', 'long']); // one uncapped source: 6 h
    final clean = [e('ok', 200)];
    expect(identical(refilterPool(config.channels[0], config, clean), clean), isTrue);
  });

  test('builds a pool from search + metadata and skips excluded ids', () async {
    final api = FakeApi({'a': (1990, 30), 'b': (1995, 30), 'c': (2001, 60)});
    final pool = await buildPool(channel, config(minHours: 1, exclude: {'b'}), api);
    expect(pool.map((e) => e.itemId), unorderedEquals(['a', 'c']));
    expect(api.queries.single, contains('-collection:(adultvhs)'));
  });

  test('an item/file exclude drops just that file, on build and on saved pools', () async {
    final api = FakeApi({'a': (1990, 30), 'c': (2001, 90)});
    final cfg = config(minHours: 1, exclude: {'c/c.mp4'});
    final pool = await buildPool(channel, cfg, api);
    expect(pool.map((e) => e.itemId), ['a']);
    final old = [...pool, Entry(id: 'c/c.mp4', itemId: 'c', file: 'c.mp4', title: 'c', durationSeconds: 300, url: 'u')];
    expect(refilterPool(channel, cfg, old).map((e) => e.id), ['a/a.mp4']);
  });

  test('thin channel widens to the fallback year and rebuilds', () async {
    final api = FakeApi({'new': (1990, 30), 'old': (1970, 120)});
    final pool = await buildPool(channel, config(), api);
    expect(pool.map((e) => e.itemId), unorderedEquals(['new', 'old']));
    expect(api.queries, hasLength(2));
    expect(api.queries.last, contains('1960-01-01 TO 2010-12-31'));
  });

  test('a channel that is big enough does not widen', () async {
    final api = FakeApi({'a': (1990, 180)});
    await buildPool(channel, config(), api);
    expect(api.queries, hasLength(1));
  });

  test('one failing item is skipped, the rest still build', () async {
    final logs = <String>[];
    final api = FakeApi({'a': (1990, 90), 'bad': (1990, 90)}, failing: {'bad'});
    final pool = await buildPool(channel, config(), api, log: logs.add);
    expect(pool.map((e) => e.itemId), ['a']);
    expect(logs.any((l) => l.contains('skip bad')), isTrue);
  });

  test('a failing source is skipped, the other source still builds the pool', () async {
    final logs = <String>[];
    const two = Channel(number: 5, name: 'Funnies', sources: [
      Source(query: 'subject:broken'),
      Source(query: 'subject:cartoon'),
    ]);
    final api = FakeApi({'a': (1990, 180)}, failQuery: 'broken');
    final pool = await buildPool(two, config(), api, log: logs.add);
    expect(pool.map((e) => e.itemId), ['a']);
    expect(logs.any((l) => l.contains('skip source')), isTrue);
  });

  test('files under 2 min stay out of normal channels; short-content and minSeconds channels keep them', () async {
    final api = FakeApi({'show': (1990, 30), 'opening': (1990, 1)});
    final normal = await buildPool(channel, config(minHours: 0), api);
    expect(normal.map((e) => e.itemId), ['show']);
    const ads = Channel(number: 22, name: 'Jingle', shortContent: 'Commercials', sources: [Source(query: 'x')]);
    expect((await buildPool(ads, config(minHours: 0), api)).map((e) => e.itemId), ['opening', 'show']);
    const ids = Channel(number: 66, name: 'Nightlight', minSeconds: 60, sources: [Source(query: 'x')]);
    expect((await buildPool(ids, config(minHours: 0), api)).length, 2);
  });

  test('a source maxSeconds drops files longer than it; other sources keep the default', () async {
    final api = FakeApi({'clip': (1990, 4), 'vhs-block': (1990, 180)});
    const ch = Channel(number: 40, name: 'Jukebox', sources: [Source(query: 'x', maxSeconds: 600)]);
    expect((await buildPool(ch, config(minHours: 0), api)).map((e) => e.itemId), ['clip']);
    expect((await buildPool(channel, config(minHours: 0), api)).length, 2);
    expect(parseChannelConfig('{"channels":[{"number":40,"name":"J","sources":[{"query":"x","maxSeconds":600}]}]}')
        .channels.single.sources.single.maxSeconds, 600);
  });

  test('weatherstar channels have no pool', () async {
    const wx = Channel(number: 1, name: 'Cumulus', type: 'weatherstar');
    expect(await buildPool(wx, config(), FakeApi({})), isEmpty);
  });

  test('a weatherstar channel with music sources gets a pool of them', () async {
    const wx = Channel(number: 1, name: 'Cumulus', type: 'weatherstar', sources: [Source(query: 'jazz')]);
    final pool = await buildPool(wx, config(minHours: 1), FakeApi({'a': (1990, 90)}));
    expect(pool.map((e) => e.itemId), ['a']);
  });

  group('concurrency, progress, probe', () {
    final twenty = {for (var i = 0; i < 20; i++) 'item${'x' * (i % 5)}$i': (1990, 10)};

    test('never more than 4 metadata calls in flight; progress reaches 20/20', () async {
      final api = FakeApi(twenty, slow: true);
      final prog = <(int, int)>[];
      await buildPool(channel, config(minHours: 1), api, onProgress: (d, t) => prog.add((d, t)));
      expect(api.maxInFlight, inInclusiveRange(2, 4));
      expect(prog.last, (20, 20));
      expect(prog, hasLength(20));
    });

    test('same content and id-sorted order for any concurrency', () async {
      final a = await buildPool(channel, config(minHours: 1), FakeApi(twenty, slow: true), concurrency: 1);
      final b = await buildPool(channel, config(minHours: 1), FakeApi(twenty, slow: true), concurrency: 8);
      expect(a.map((e) => e.id).toList(), b.map((e) => e.id).toList());
      final ids = a.map((e) => e.id).toList();
      expect(ids, [...ids]..sort());
    });

    // item names ending in an even digit have the index at the front.
    http.Client probe() => MockClient((req) async {
          final fast = RegExp(r'[02468]\.mp4').hasMatch(req.url.path);
          return http.Response(fast ? 'xxmoovxxmdat' : 'xxmdatxxmoov', 206);
        });
    final ten = {for (var i = 0; i < 10; i++) 'it$i': (1990, 30)};

    test('plenty of content: non-faststart entries are dropped', () async {
      final pool = await buildPool(channel, config(minHours: 1), FakeApi(ten), probeClient: probe());
      expect(pool, hasLength(5));
      expect(pool.every((e) => e.faststart == true), isTrue);
    });

    test('thin channel keeps non-faststart entries, tagged', () async {
      final pool = await buildPool(channel, config(minHours: 4), FakeApi(ten), probeClient: probe());
      expect(pool, hasLength(10));
      expect(pool.where((e) => e.faststart == false), hasLength(5));
    });
  });

  group('captions and widening', () {
    test('wideningStarts: 1960, 1940, 1920, no limit; only years before the start', () {
      expect(wideningStarts(1980, 1960), [1960, 1940, 1920, 1800]);
      expect(wideningStarts(1960, 1960), [1940, 1920, 1800]);
      expect(wideningStarts(1930, 1960), [1920, 1800]);
    });

    test('widens step by step, newest first, and stops once the minimum is met', () async {
      final api = FakeApi({'new': (1990, 30), 'mid': (1950, 30), 'old': (1945, 120), 'ancient': (1910, 120)});
      final pool = await buildPool(channel, config(), api);
      expect(pool.map((e) => e.itemId), unorderedEquals(['new', 'mid', 'old']));
      expect(api.queries, hasLength(3));
      expect(api.queries[1], contains('1960-01-01 TO 2010-12-31'));
      expect(api.queries[2], contains('1940-01-01 TO 2010-12-31'));
      expect(api.metadataCalls, 3, reason: 'items are fetched once across widening steps');
    });

    test('a channel whose sources all ignore the year does not widen', () async {
      const fixed = Channel(number: 5, name: 'Fixed', sources: [Source(identifiers: ['new'], ignoreYear: true)]);
      final api = FakeApi({'new': (1990, 30)});
      await buildPool(fixed, config(), api);
      expect(api.queries, hasLength(1));
    });

    test('goes to no lower limit when still thin', () async {
      final api = FakeApi({'new': (1990, 30), 'ancient': (1905, 120)});
      final pool = await buildPool(channel, config(), api);
      expect(pool.map((e) => e.itemId), unorderedEquals(['new', 'ancient']));
      expect(api.queries.last, contains('1800-01-01 TO 2010-12-31'));
    });

    test('foreign items without a sidecar stay in the pool but do not count; with one they do', () async {
      final api = FakeApi({'fr': (1990, 180), 'old': (1950, 30)}, tags: {'fr': (lang: 'fre', silent: false, sub: false)});
      final pool = await buildPool(channel, config(), api);
      expect(pool.map((e) => e.itemId), unorderedEquals(['fr', 'old']));
      expect(api.queries, hasLength(5), reason: 'widened all the way: nothing comprehensible was enough');

      final subbed = FakeApi({'fr': (1990, 180)}, tags: {'fr': (lang: 'French', silent: false, sub: true)});
      final p2 = await buildPool(channel, config(), subbed);
      expect(subbed.queries, hasLength(1));
      expect(p2.single.foreign, isTrue);
      expect(p2.single.subUrl, 'https://archive.org/download/fr/fr.en.srt');
    });

    test('silent films brought in by widening are only kept when needed', () async {
      final tags = {'silent': (lang: null, silent: true, sub: false)};
      final enough = FakeApi({'new': (1990, 60), 'silent': (1925, 120), 'talkie': (1935, 90)}, tags: tags);
      expect((await buildPool(channel, config(), enough)).map((e) => e.itemId), unorderedEquals(['new', 'talkie']));

      final short = FakeApi({'new': (1990, 60), 'silent': (1925, 120)}, tags: tags);
      expect((await buildPool(channel, config(), short)).map((e) => e.itemId), unorderedEquals(['new', 'silent']));
    });
  });

  test('maxEntries caps a source round-robin over its items; other sources untouched', () async {
    Entry e(String item, int i) => Entry(id: '$item/$i', itemId: item, file: '$i', title: '$i', durationSeconds: 60, url: 'u');
    const capped = Source(query: 'a', maxEntries: 4);
    const free = Source(query: 'b');
    final pool = [for (var i = 0; i < 6; i++) e('big', i), e('small', 0), e('small', 1), for (var i = 0; i < 3; i++) e('other', i)];
    final out = capPerSource(pool, (x) => x.itemId == 'other' ? free : capped);
    expect(out.where((x) => x.itemId != 'other').map((x) => x.id), ['big/0', 'big/1', 'small/0', 'small/1']);
    expect(out.where((x) => x.itemId == 'other'), hasLength(3));

    final api = FakeApi({'x': (1990, 30), 'y': (1990, 30)});
    final ch = Channel(number: 9, name: 'Cap', sources: const [Source(query: 'q', maxEntries: 1)]);
    expect(await buildPool(ch, config(), api), hasLength(1));
  });

  test('maxEntriesPerItem thins one huge item evenly, before maxEntries; small items untouched', () {
    Entry e(String item, int i) =>
        Entry(id: '$item/${i.toString().padLeft(3, '0')}', itemId: item, file: '$i', title: '$i', durationSeconds: 60, url: 'u');
    const perItem = Source(query: 'a', maxEntriesPerItem: 4);
    final pool = [for (var i = 0; i < 135; i++) e('jazz', i), e('rock', 0), e('rock', 1)];
    final out = capPerSource(pool, (_) => perItem);
    expect(out.where((x) => x.itemId == 'jazz').map((x) => x.id), ['jazz/000', 'jazz/033', 'jazz/067', 'jazz/101']);
    expect(out.where((x) => x.itemId == 'rock'), hasLength(2));

    const both = Source(query: 'a', maxEntriesPerItem: 4, maxEntries: 5);
    expect(capPerSource(pool, (_) => both).map((x) => x.id), ['jazz/000', 'jazz/033', 'jazz/067', 'rock/000', 'rock/001']);
  });
}
