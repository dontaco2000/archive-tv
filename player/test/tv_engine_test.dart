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
    expect(engine.tunable.map((c) => c.name), ['Bytes', 'Thin']); // 195 min each; weatherstar excluded
    final thinApi = FakeApi({'a': 30});
    final thin = TvEngine.open(configText: configText, dataDir: Directory.systemTemp.createTempSync('thin'), api: thinApi);
    await thin.ensurePool(thin.channels.first);
    expect(thin.tunable, isEmpty);
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
    expect(empty.tunable, isEmpty);
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
}

class _Failing implements ArchiveApi {
  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) => throw ArchiveException('offline');

  @override
  Future<ItemMeta?> metadata(String identifier) => throw ArchiveException('offline');
}
