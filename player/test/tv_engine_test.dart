import 'dart:async';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:archive_tv_player/engine/tv_engine.dart';

/// Archive stand-in: each item is one video of the given minutes.
class FakeApi implements ArchiveApi {
  final Map<String, int> minutes;
  int searches = 0;
  FakeApi(this.minutes);

  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async {
    searches++;
    return [for (final id in minutes.keys) ItemSummary(id)];
  }

  @override
  Future<ItemMeta?> metadata(String identifier) async => ItemMeta(identifier, title: identifier, files: [
        ArchiveFile('$identifier.mp4', format: 'h.264', length: minutes[identifier]! * 60.0),
      ]);
}

/// [FakeApi] whose searches wait for [open].
class GatedApi extends FakeApi {
  final open = Completer<void>();
  GatedApi(super.minutes);

  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async {
    searches++;
    await open.future;
    return [for (final id in minutes.keys) ItemSummary(id)];
  }
}

const configText = '''
{
  "channels": [
    {"number": 2, "name": "Bytes", "sources": [{"query": "x"}]},
    {"number": 3, "name": "Thin", "sources": [{"query": "y"}]},
    {"number": 9, "name": "Cumulus", "type": "weatherstar"}
  ]
}
''';

void main() {
  late Directory dir;
  late FakeApi api;
  late TvEngine engine;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('engine');
    api = FakeApi({'a': 60, 'b': 45, 'c': 90});
    engine = TvEngine.open(configText: configText, dataDir: dir, api: api);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('tunable lists only archive channels with at least 2 hours of content', () async {
    for (final c in engine.channels) {
      await engine.ensurePool(c);
    }
    expect(engine.tunable.map((c) => c.name), ['Bytes', 'Thin', 'Cumulus']); // 195 min each; weather is always on
    final thinApi = FakeApi({'a': 30});
    final thin = TvEngine.open(configText: configText, dataDir: Directory.systemTemp.createTempSync('thin'), api: thinApi);
    await thin.ensurePool(thin.channels.first);
    expect(thin.tunable.map((c) => c.name), ['Cumulus']);
  });

  test('statusOf: building until the first load/build finishes, then ready or failed', () async {
    final bytes = engine.channels[0], cumulus = engine.channels[2];
    expect(engine.statusOf(cumulus), PoolStatus.ready); // weather is always on
    expect(engine.statusOf(bytes), PoolStatus.building); // not tried yet (queued at startup)
    var bumps = 0;
    engine.poolsChanged.addListener(() => bumps++);
    final f = engine.ensurePool(bytes);
    expect(engine.statusOf(bytes), PoolStatus.building); // build running
    await f;
    expect(engine.statusOf(bytes), PoolStatus.ready);
    expect(bumps, 1);

    final thin = TvEngine.open(configText: configText, dataDir: Directory.systemTemp.createTempSync('thin'), api: FakeApi({'a': 30}));
    await thin.ensurePool(thin.channels.first);
    expect(thin.statusOf(thin.channels.first), PoolStatus.failed); // too little content

    final broken = TvEngine.open(configText: configText, dataDir: Directory.systemTemp.createTempSync('broken'), api: FakeApi({}));
    await broken.ensurePool(broken.channels.first);
    expect(broken.statusOf(broken.channels.first), PoolStatus.failed); // build found nothing
    expect(broken.statusOf(broken.channels[1]), PoolStatus.building); // still queued
  });

  Entry old(String id, {double seconds = 3600}) =>
      Entry(id: '$id/f.mp4', itemId: id, file: 'f.mp4', title: id, durationSeconds: seconds, url: 'u');

  test('a stale saved pool (sources since changed) is ready at once, stays on air while dailyRefresh rebuilds it, then swaps', () async {
    final bytes = engine.channels.first;
    engine.pools.save(bytes.number, [old('old1'), old('old2'), old('old3')], builtAt: DateTime(2026, 1, 1));
    final gate = GatedApi({'a': 60, 'b': 45, 'c': 90});
    final e = TvEngine.open(configText: configText, dataDir: dir, api: gate);
    await e.ensurePool(bytes);
    expect(gate.searches, 0);
    expect(e.statusOf(bytes), PoolStatus.ready);
    expect(e.tunable.map((c) => c.number), contains(bytes.number));
    final now = DateTime.now();
    e.planWeek(bytes, now); // today + 6 days saved from the old pool
    final todayOld = e.guideFor(bytes, DateTime(now.year, now.month, now.day), hours: 24).first.entry.id;

    final refresh = e.dailyRefresh(now);
    await pumpEventQueue();
    expect(gate.searches, greaterThan(0)); // rebuild running...
    expect(e.statusOf(bytes), PoolStatus.ready); // ...behind the old pool
    expect(e.poolOf(bytes).map((x) => x.itemId), ['old1', 'old2', 'old3']);
    gate.open.complete();
    await refresh;
    expect(e.poolOf(bytes).map((x) => x.itemId), ['a', 'b', 'c']); // swapped
    expect(e.guideFor(bytes, DateTime(now.year, now.month, now.day), hours: 24).first.entry.id, todayOld); // today kept
    final tomorrow = e.guideFor(bytes, DateTime(now.year, now.month, now.day + 1), hours: 24);
    expect(tomorrow.every((s) => ['a', 'b', 'c'].contains(s.entry.itemId)), isTrue); // later days from the new pool
  });

  test('no saved pool: building until built', () async {
    final bytes = engine.channels.first;
    final gate = GatedApi({'a': 60, 'b': 45, 'c': 90});
    final e = TvEngine.open(configText: configText, dataDir: dir, api: gate);
    final f = e.ensurePool(bytes);
    await pumpEventQueue();
    expect(e.statusOf(bytes), PoolStatus.building);
    expect(e.tunable.map((c) => c.number), isNot(contains(bytes.number)));
    gate.open.complete();
    await f;
    expect(e.statusOf(bytes), PoolStatus.ready);
  });

  test('an old pool is cut to the current excludes/length limits; too little left = building', () async {
    const excl = '{"excludeIdentifiers": ["bad1", "bad2"], '
        '"channels": [{"number": 2, "name": "Bytes", "sources": [{"query": "x", "maxSeconds": 6000}]}]}';
    final bytes = TvEngine.open(configText: excl, dataDir: dir, api: api).channels.first;
    // 3 h left after the cut: served at once without the excluded / too long / too short items, no network.
    PoolStore(Directory('${dir.path}/pools')).save(bytes.number,
        [old('bad1'), old('ok1'), old('ok2'), old('ok3'), old('long', seconds: 7200), old('short', seconds: 30)],
        builtAt: DateTime(2026, 1, 1));
    final e = TvEngine.open(configText: excl, dataDir: dir, api: api);
    await e.ensurePool(bytes);
    expect(api.searches, 0);
    expect(e.statusOf(bytes), PoolStatus.ready);
    expect(e.poolOf(bytes).map((x) => x.itemId), ['ok1', 'ok2', 'ok3']);
    final now = DateTime(2026, 11, 11, 12);
    expect(e.guideFor(bytes, now, hours: 24).every((s) => s.entry.itemId.startsWith('ok')), isTrue);

    // Only 1 h left after the cut: not served, the channel builds.
    final dir2 = Directory.systemTemp.createTempSync('engine2');
    PoolStore(Directory('${dir2.path}/pools'))
        .save(bytes.number, [old('bad1'), old('bad2'), old('ok1')], builtAt: DateTime(2026, 1, 1));
    final gate = GatedApi({'a': 60, 'b': 45, 'c': 90});
    final e2 = TvEngine.open(configText: excl, dataDir: dir2, api: gate);
    final f = e2.ensurePool(bytes);
    await pumpEventQueue();
    expect(e2.statusOf(bytes), PoolStatus.building);
    gate.open.complete();
    await f;
    expect(e2.statusOf(bytes), PoolStatus.ready);
    dir2.deleteSync(recursive: true);
  });

  test('airing gives the slot, offset into it and the next slot', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final now = DateTime(2026, 11, 11, 15, 20, 5);
    final a = engine.airing(bytes, now)!;
    expect(!now.isBefore(a.slot.start) && now.isBefore(a.slot.end), isTrue);
    expect(a.offsetSeconds, closeTo(now.difference(a.slot.start).inMilliseconds / 1000, 0.001));
    expect(a.next!.start, a.slot.end);
    // Same moment, same answer (deterministic across calls and restarts).
    expect(engine.airing(bytes, now)!.slot.entry.id, a.slot.entry.id);
  });

  test('markBad drops the item from airing and the guide, slots still tile, nothing on disk', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final now = DateTime(2026, 11, 11, 15, 20, 5);
    final bad = engine.airing(bytes, now)!.slot.entry.id;
    engine.markBad(bytes, bad);
    expect(engine.airing(bytes, now)!.slot.entry.id, isNot(bad));
    final slots = engine.guideFor(bytes, DateTime(2026, 11, 11, 0, 0, 1), hours: 24);
    expect(slots.any((s) => s.entry.id == bad), isFalse);
    expect(slots.first.start, DateTime(2026, 11, 11));
    for (var i = 1; i < slots.length; i++) {
      expect(slots[i].start, slots[i - 1].end);
    }
    expect(TvEngine.open(configText: configText, dataDir: dir, api: api).blocklist.ids, isEmpty);
  });

  test('markWrongChannel: logged, gone from that channel now and after a restart, other channels keep it', () async {
    final four = FakeApi({'a': 60, 'b': 45, 'c': 90, 'd': 60});
    final e = TvEngine.open(configText: configText, dataDir: dir, api: four);
    final bytes = e.channels[0], thin = e.channels[1];
    await e.ensurePool(bytes);
    await e.ensurePool(thin);
    final now = DateTime(2026, 11, 11, 15, 20, 5);
    final victim = e.airing(bytes, now)!.slot.entry;
    e.markWrongChannel(bytes, victim, now: now);
    expect(e.airing(bytes, now)!.slot.entry.itemId, isNot(victim.itemId));
    expect(e.guideFor(bytes, now, hours: 24).any((s) => s.entry.itemId == victim.itemId), isFalse);
    expect(e.poolOf(bytes).any((x) => x.itemId == victim.itemId), isFalse);
    expect(e.poolOf(thin).any((x) => x.itemId == victim.itemId), isTrue); // only that channel
    final line = File('${dir.path}/wrong_channel.jsonl').readAsLinesSync().single;
    expect(line, contains('"channel":2'));
    expect(line, contains('"itemId":"${victim.itemId}"'));

    final again = TvEngine.open(configText: configText, dataDir: dir, api: four); // restart: saved pool + saved list
    await again.ensurePool(bytes);
    expect(again.poolOf(bytes).any((x) => x.itemId == victim.itemId), isFalse);
    expect(again.statusOf(bytes), PoolStatus.ready);
  });

  test('probeUpcoming keeps slow-start files out of the schedule and remembers them', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final probed = <String>[];
    // File b has its mp4 index at the end; a and c are faststart.
    final client = MockClient((req) async {
      probed.add(req.url.path);
      final boxes = req.url.path.endsWith('/b.mp4') ? 'ftypmdatmoov' : 'ftypmoovmdat';
      return http.Response.bytes(boxes.codeUnits, 206);
    });
    final now = DateTime(2026, 11, 11, 15, 20, 5);
    expect(await engine.probeUpcoming(bytes, now, client), 1);
    expect(probed.toSet(), {'/download/a/a.mp4', '/download/b/b.mp4', '/download/c/c.mp4'});
    expect(probed, hasLength(3)); // each file once, however often it airs
    expect(engine.guideFor(bytes, now).any((s) => s.entry.itemId == 'b'), isFalse);
    expect(TvEngine.open(configText: configText, dataDir: dir, api: api).slow.ids, {'b/b.mp4'});
  });

  test('probeUpcoming never makes a channel too thin', () async {
    final thin = TvEngine.open(configText: configText, dataDir: dir, api: FakeApi({'a': 70, 'b': 60}));
    final bytes = thin.channels.first;
    await thin.ensurePool(bytes);
    final allSlow = MockClient((_) async => http.Response.bytes('ftypmdatmoov'.codeUnits, 206));
    expect(await thin.probeUpcoming(bytes, DateTime(2026, 11, 11, 15), allSlow), 2);
    expect(thin.slow.ids, isEmpty);
  });

  test('markNoSubs: gone from airing, guide and On Demand, and stays gone after a restart', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final now = DateTime(2026, 11, 11, 15, 20, 5);
    final id = engine.airing(bytes, now)!.slot.entry.id;
    engine.markNoSubs(bytes, id);
    expect(engine.airing(bytes, now)!.slot.entry.id, isNot(id));
    expect(engine.poolOf(bytes).any((e) => e.id == id), isFalse);
    final again = TvEngine.open(configText: configText, dataDir: dir, api: api);
    expect(again.noSubs.ids, {id});
    await again.ensurePool(bytes);
    expect(again.guideFor(bytes, DateTime(2026, 11, 12, 0, 0, 1), hours: 24).any((s) => s.entry.id == id), isFalse);
    expect(again.poolOf(bytes).any((e) => e.id == id), isFalse);
  });

  test('fresh: an entry from an older saved day is replaced by the pool copy (with language/subtitles)', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final p = engine.poolOf(bytes).first;
    final stale = Entry(id: p.id, itemId: p.itemId, file: p.file, title: 'old', durationSeconds: 1, url: 'x');
    expect(engine.fresh(bytes, stale), same(p));
    const unknown = Entry(id: 'zz/z.mp4', itemId: 'zz', file: 'z.mp4', title: 'z', durationSeconds: 1, url: 'x');
    expect(engine.fresh(bytes, unknown), same(unknown));
  });

  test('airing at the last slot of the day looks ahead to the first slot of tomorrow', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final a = engine.airing(bytes, DateTime(2026, 11, 11, 23, 59, 59))!;
    expect(a.next!.start, DateTime(2026, 11, 12));
  });

  test('a saved pool is reused within a day and rebuilt after', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    expect(api.searches, 1);

    final again = TvEngine.open(configText: configText, dataDir: dir, api: api);
    await again.ensurePool(bytes);
    expect(api.searches, 1); // loaded from disk

    final stale = TvEngine.open(configText: configText, dataDir: dir, api: api);
    await stale.ensurePool(bytes, maxAge: Duration.zero);
    expect(api.searches, 2);
  });

  test('maxAge zero rebuilds a pool that is already loaded', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    await engine.ensurePool(bytes);
    expect(api.searches, 1); // loaded pool is kept
    await engine.ensurePool(bytes, maxAge: Duration.zero);
    expect(api.searches, 2);
    expect(engine.tunable.map((c) => c.name), contains('Bytes'));
  });

  test('a failed rebuild falls back to the stale pool', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final broken = TvEngine.open(configText: configText, dataDir: dir, api: _Failing());
    await broken.ensurePool(bytes, maxAge: Duration.zero);
    expect(broken.tunable.map((c) => c.name), contains('Bytes'));
  });

  test('concurrent ensurePool calls share one build', () async {
    final bytes = engine.channels.first;
    await Future.wait([engine.ensurePool(bytes), engine.ensurePool(bytes)]);
    expect(api.searches, 1);
  });

  test('an empty build is not saved, and a later ensurePool builds normally', () async {
    final bytes = engine.channels.first;
    final empty = TvEngine.open(configText: configText, dataDir: dir, api: FakeApi({}));
    await empty.ensurePool(bytes);
    expect(empty.tunable.map((c) => c.name), ['Cumulus']);
    expect(File('${dir.path}/pools/pool-2.json').existsSync(), isFalse);
    await empty.ensurePool(bytes); // retried, not cached as empty
    await engine.ensurePool(bytes);
    expect(engine.tunable.map((c) => c.name), contains('Bytes'));
  });

  test('guideFor covers 12 hours and planWeek saves seven days', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    final now = DateTime(2026, 11, 11, 20);
    final g = engine.guideFor(bytes, now);
    expect(g.first.start.isAfter(now), isFalse);
    expect(g.last.start.isBefore(now.add(const Duration(hours: 12))), isTrue);
    engine.planWeek(bytes, now);
    final saved = Directory('${dir.path}/days').listSync().where((f) => f.path.contains('day-2-'));
    expect(saved, hasLength(7));
  });

  test('dailyRefresh rebuilds only stale pools, plans the new week and drops past days', () async {
    final bytes = engine.channels.first;
    await engine.ensurePool(bytes);
    engine.planWeek(bytes, DateTime(2026, 11, 10)); // yesterday's week
    await engine.dailyRefresh(DateTime(2026, 11, 11, 0, 0, 1));
    expect(api.searches, 2); // Bytes is fresh and kept; Thin had no pool and is built
    await engine.dailyRefresh(DateTime(2026, 11, 11, 0, 0, 1), maxAge: Duration.zero);
    expect(api.searches, 4); // both rebuilt
    final days = Directory('${dir.path}/days').listSync().map((f) => f.path).where((p) => p.contains('day-2-')).toList();
    expect(days.any((p) => p.contains('2026-11-10')), isFalse);
    expect(days.any((p) => p.contains('2026-11-17')), isTrue);
  });

  test('serial blocks air in prime time as "Show S1E3", in order, and never in the shuffle', () async {
    final eps = [for (var i = 1; i <= 8; i++) 'e$i'];
    final serialApi = FakeApi({'a': 60, 'b': 45, 'c': 90, for (final e in eps) e: 23});
    final cfg = '{"channels": [{"number": 2, "name": "Bytes", "sources": [{"query": "x"}], "serials": ['
        '{"start": "20:00", "epoch": "2026-11-11", "shows": [{"title": "Death Note", '
        '"identifiers": ["${eps.join('","')}"], "order": ["${eps.map((e) => '$e.mp4').join('","')}"]}]}]}]}';
    final e = TvEngine.open(configText: cfg, dataDir: dir, api: serialApi);
    final c = e.channels.single;
    await e.ensurePool(c);
    final a = e.airing(c, DateTime(2026, 11, 12, 20, 10))!;
    expect(a.slot.entry.title, 'Death Note S1E3'); // second day, two 23-min episodes a night
    expect(a.slot.start, DateTime(2026, 11, 12, 20));
    final day = e.guideFor(c, DateTime(2026, 11, 12, 0, 0, 1), hours: 24);
    expect(day.where((s) => s.entry.itemId.startsWith('e')).map((s) => s.entry.title), ['Death Note S1E3', 'Death Note S1E4']);
    expect(File('${dir.path}/pools/serials-2.json').existsSync(), isTrue);
  });
}

class _Failing implements ArchiveApi {
  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) => throw ArchiveException('offline');

  @override
  Future<ItemMeta?> metadata(String identifier) => throw ArchiveException('offline');
}
