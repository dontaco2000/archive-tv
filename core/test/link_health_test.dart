import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Entry e(String id) => Entry(
    id: 'item$id/f$id.mp4', itemId: 'item$id', file: 'f$id.mp4', title: 'Title $id', durationSeconds: 1800, url: 'https://archive.org/download/item$id/f$id.mp4');

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('linkhealth'));
  tearDown(() => dir.deleteSync(recursive: true));

  /// Answers by the item number in the URL from [codes] (default 200); records methods and concurrency.
  ({MockClient client, List<String> methods, int Function() maxInFlight}) fake(Map<String, int> codes, {Duration wait = Duration.zero}) {
    final methods = <String>[];
    var inFlight = 0, max = 0;
    final client = MockClient((req) async {
      methods.add(req.method);
      inFlight++;
      if (inFlight > max) max = inFlight;
      await Future<void>.delayed(wait);
      inFlight--;
      final id = RegExp(r'item(\w+)/').firstMatch(req.url.path)!.group(1)!;
      return http.Response('', codes[id] ?? 200);
    });
    return (client: client, methods: methods, maxInFlight: () => max);
  }

  DeadLinkChecker checker(http.Client c, LinkHealth h, {int concurrency = 2}) =>
      DeadLinkChecker(c, h, concurrency: concurrency, delay: Duration.zero, backoff: Duration.zero);

  final t0 = DateTime(2026, 11, 12, 10);
  final pool = [for (var i = 1; i <= 10; i++) e('$i')];

  test('classifies status codes', () {
    expect(classifyStatus(200), LinkCheck.ok);
    expect(classifyStatus(206), LinkCheck.ok);
    for (final c in [404, 403, 410]) {
      expect(classifyStatus(c), LinkCheck.miss);
    }
    expect(classifyStatus(500), LinkCheck.inconclusive);
    expect(classifyStatus(502), LinkCheck.inconclusive);
    expect(classifyStatus(429), LinkCheck.throttled);
    expect(classifyStatus(503), LinkCheck.throttled);
  });

  test('a 404 on two passes an hour apart marks the entry dead and logs it', () async {
    final f = fake({'3': 404});
    final h = LinkHealth.load(dir);
    expect(await checker(f.client, h).checkChannel(2, 'Funnies', pool, now: () => t0), isEmpty);
    expect(h.struck(pool[2].id), isTrue);
    // a second miss inside the hour is the same pass window: no verdict yet
    expect(await checker(f.client, h).checkChannel(2, 'Funnies', [pool[2]], now: () => t0.add(const Duration(minutes: 20))), isEmpty);
    final dead = await checker(f.client, h).checkChannel(2, 'Funnies', [pool[2]], now: () => t0.add(const Duration(hours: 1)));
    expect(dead.map((x) => x.id), [pool[2].id]);
    expect(h.dead.ids, {pool[2].id});
    expect(h.struck(pool[2].id), isFalse);
    final log = h.logFile.readAsStringSync();
    expect(log, contains('Title 3'));
    expect(log, contains('item item3'));
    expect(log, contains('first miss 2026-11-12 10:00, second 2026-11-12 11:00 (HTTP 404)'));
    expect(f.methods.toSet(), {'HEAD'});
    // the dead list is a Blocklist the scheduler applies
    expect(h.dead.apply(pool).length, 9);
  });

  test('one success between misses clears the strike', () async {
    var code = 404;
    final client = MockClient((_) async => http.Response('', code));
    final h = LinkHealth.load(dir);
    await checker(client, h).checkChannel(1, 'A', [pool[0]], now: () => t0);
    expect(h.struck(pool[0].id), isTrue);
    code = 200;
    await checker(client, h).checkChannel(1, 'A', [pool[0]], now: () => t0.add(const Duration(hours: 1)));
    expect(h.struck(pool[0].id), isFalse);
    code = 404;
    h.okAt.clear();
    expect(await checker(client, h).checkChannel(1, 'A', [pool[0]], now: () => t0.add(const Duration(hours: 2))), isEmpty);
    expect(h.dead.ids, isEmpty);
  });

  test('5xx, timeouts and network errors never strike', () async {
    final h = LinkHealth.load(dir);
    for (final c in [MockClient((_) async => http.Response('', 500)), MockClient((_) async => throw http.ClientException('down'))]) {
      for (final t in [t0, t0.add(const Duration(hours: 2))]) {
        expect(await checker(c, h).checkChannel(1, 'A', [pool[0]], now: () => t), isEmpty);
      }
    }
    expect(h.strikes, isEmpty);
    expect(h.dead.ids, isEmpty);
  });

  test('a pass where more than 30% miss is discarded', () async {
    final f = fake({'1': 404, '2': 404, '3': 404, '4': 404});
    final h = LinkHealth.load(dir);
    expect(await checker(f.client, h).checkChannel(1, 'A', pool, now: () => t0), isEmpty);
    expect(h.strikes, isEmpty);
    // 2 of 10 is under the line: those strike
    final g = fake({'1': 404, '2': 404});
    h.okAt.clear();
    await checker(g.client, h).checkChannel(1, 'A', pool, now: () => t0);
    expect(h.strikes.keys.toSet(), {pool[0].id, pool[1].id});
  });

  test('concurrency is respected and HEAD 405 falls back to a 1-byte GET', () async {
    final f = fake({}, wait: const Duration(milliseconds: 5));
    await checker(f.client, LinkHealth.load(dir), concurrency: 2).checkChannel(1, 'A', pool);
    expect(f.maxInFlight(), 2);
    final one = fake({}, wait: const Duration(milliseconds: 5));
    await checker(one.client, LinkHealth.load(dir), concurrency: 1).checkChannel(1, 'A', pool);
    expect(one.maxInFlight(), 1);

    final seen = <String>[];
    final c = MockClient((req) async {
      seen.add('${req.method} ${req.headers['Range'] ?? ''}'.trim());
      return http.Response('', req.method == 'HEAD' ? 405 : 206);
    });
    expect((await checkLink(c, pool[0].url)).$1, LinkCheck.ok);
    expect(seen, ['HEAD', 'GET bytes=0-0']);
  });

  test('a 503 for an item Archive no longer has (metadata {} or is_dark) is a miss; for a live item, a throttle', () async {
    Future<LinkCheck> run(String meta) async {
      final c = MockClient((req) async =>
          req.url.path.startsWith('/metadata/item1') ? http.Response(meta, 200) : http.Response('', 503));
      return (await checkLink(c, pool[0].url)).$1;
    }

    expect(await run('{}'), LinkCheck.miss);
    expect(await run('{"is_dark": true}'), LinkCheck.miss);
    expect(await run('{"files": []}'), LinkCheck.throttled);
  });

  test('429/503 back off, and four of them end the run', () async {
    final sleeps = <Duration>[];
    final client = MockClient((_) async => http.Response('', 429));
    final c = DeadLinkChecker(client, LinkHealth.load(dir),
        concurrency: 1, delay: Duration.zero, backoff: const Duration(seconds: 30), sleep: (d) async => sleeps.add(d));
    await c.checkChannel(1, 'A', pool);
    expect(c.gaveUp, isTrue);
    expect(sleeps.where((d) => d > Duration.zero), [30, 60, 120, 240].map((s) => Duration(seconds: s)));
    expect(c.health.strikes, isEmpty);
  });

  test('entries seen fine recently are not asked again', () async {
    final f = fake({});
    final h = LinkHealth.load(dir);
    await checker(f.client, h).checkChannel(1, 'A', pool, now: () => t0);
    await checker(f.client, h).checkChannel(1, 'A', pool, now: () => t0.add(const Duration(hours: 1)));
    expect(f.methods.length, 10);
  });

  test('strikes and the dead list survive a restart', () async {
    final h = LinkHealth.load(dir);
    await checker(fake({'1': 404}).client, h).checkChannel(1, 'A', pool, now: () => t0);
    h.dead.add('gone/x.mp4');
    final again = LinkHealth.load(dir);
    expect(again.strikes[pool[0].id]!['first'], t0.toIso8601String());
    expect(again.strikes[pool[0].id]!['code'], 404);
    expect(again.dead.ids, {'gone/x.mp4'});
    expect(again.hasDue(t0.add(const Duration(minutes: 30))), isFalse);
    expect(again.hasDue(t0.add(const Duration(hours: 1))), isTrue);
    // and the second miss after the restart makes it dead
    final dead = await checker(fake({'1': 404}).client, again).checkChannel(1, 'A', [pool[0]], now: () => t0.add(const Duration(hours: 3)));
    expect(dead.length, 1);
  });

  group('dead rechecks', () {
    final codes = <String, int>{'1': 404};
    final asked = <String>[];
    final client = MockClient((req) async {
      final id = RegExp(r'item(\w+)/').firstMatch(req.url.path)!.group(1)!;
      asked.add(id);
      return http.Response('', codes[id] ?? 200);
    });
    final day = const Duration(days: 1);

    /// A full pass at [t]: the healthy rest of the pool, then the dead rechecks.
    Future<({List<String> revived, List<String> gone})> pass(LinkHealth h, DateTime t, {List<Entry>? channel}) async {
      h.okAt.clear();
      final c = checker(client, h);
      await c.checkChannel(1, 'A', channel ?? pool.sublist(1), now: () => t);
      return c.recheckDead(now: () => t);
    }

    Future<LinkHealth> deadOne() async {
      codes
        ..clear()
        ..['1'] = 404;
      final h = LinkHealth.load(dir);
      await checker(client, h).checkChannel(1, 'A', [pool[0]], now: () => t0);
      await checker(client, h).checkChannel(1, 'A', [pool[0]], now: () => t0.add(const Duration(hours: 1)));
      expect(h.dead.ids, {pool[0].id});
      expect(h.deadInfo[pool[0].id]!['url'], pool[0].url);
      return h;
    }

    test('weekly spacing: no recheck before 6 days, then one', () async {
      final h = await deadOne();
      asked.clear();
      await pass(h, t0.add(day * 5));
      expect(asked, isNot(contains('1')));
      await pass(h, t0.add(day * 6 + const Duration(hours: 1)));
      expect(asked.where((a) => a == '1').length, 1);
      expect(h.deadInfo[pool[0].id]!['rechecks'], 1);
      asked.clear();
      await pass(h, t0.add(day * 8)); // two days after that recheck: not again
      expect(asked, isNot(contains('1')));
    });

    test('a dead file that answers again is revived: off dead.json, logged', () async {
      final h = await deadOne();
      codes['1'] = 200;
      final r = await pass(h, t0.add(day * 7));
      expect(r.revived, [pool[0].id]);
      expect(h.dead.ids, isEmpty);
      expect(h.deadInfo, isEmpty);
      expect(LinkHealth.load(dir).dead.ids, isEmpty);
      expect(h.logFile.readAsStringSync(), contains('revived  "Title 1"'));
    });

    test('three failed rechecks: gone for good, still blocked, never asked again', () async {
      final h = await deadOne();
      for (var week = 1; week <= 3; week++) {
        final r = await pass(h, t0.add(day * 7 * week));
        expect(r.gone, week == 3 ? [pool[0].id] : isEmpty);
      }
      expect(h.isGone(pool[0].id), isTrue);
      expect(h.dead.ids, {pool[0].id}); // still blocked
      expect(h.activeDead, 0);
      expect(h.logFile.readAsStringSync(), contains('removed for good  "Title 1"'));
      asked.clear();
      await pass(h, t0.add(day * 100));
      expect(asked, isNot(contains('1')));
    });

    test('inconclusive rechecks count for nothing and stay due', () async {
      final h = await deadOne();
      codes['1'] = 500;
      await pass(h, t0.add(day * 7));
      expect(h.deadInfo[pool[0].id]!['rechecks'], 0);
      expect(h.dead.ids, {pool[0].id});
      asked.clear();
      await pass(h, t0.add(day * 7 + const Duration(hours: 12)));
      expect(asked, contains('1')); // still due
    });

    test('valve: no rechecks when the channel pass was discarded or nothing answered OK', () async {
      final h = await deadOne();
      codes
        ..['2'] = 404
        ..['3'] = 404
        ..['4'] = 404; // 3 of 9 miss: the channel pass is discarded
      asked.clear();
      final r = await pass(h, t0.add(day * 7));
      expect(r.revived, isEmpty);
      expect(asked, isNot(contains('1')));
      expect(h.deadInfo[pool[0].id]!['rechecks'], 0);
      codes
        ..remove('2')
        ..remove('3')
        ..remove('4')
        ..['1'] = 200;
      h.okAt.clear();
      // nothing else checked in this pass, nothing OK within the hour: put off
      expect((await checker(client, h).recheckDead(now: () => t0.add(day * 7))).revived, isEmpty);
      expect(h.dead.ids, {pool[0].id});
      // a healthy pass revives it
      expect((await pass(h, t0.add(day * 7))).revived, [pool[0].id]);
    });

    test('recheck counts persist; the old strikes-only link_health.json and a bare dead.json still load', () async {
      final h = await deadOne();
      await pass(h, t0.add(day * 7));
      expect(LinkHealth.load(dir).deadInfo[pool[0].id]!['rechecks'], 1);

      final old = Directory.systemTemp.createTempSync('linkold');
      addTearDown(() => old.deleteSync(recursive: true));
      File('${old.path}/link_health.json').writeAsStringSync('{"a/b.mp4": {"first": "2026-11-12T10:00:00.000", "code": 404}}');
      File('${old.path}/dead.json').writeAsStringSync('["item1/f1.mp4"]');
      final o = LinkHealth.load(old);
      expect(o.struck('a/b.mp4'), isTrue);
      expect(o.dueRechecks(t0).single.url, 'https://archive.org/download/item1/f1.mp4'); // no record: due now
      o.save();
      expect(LinkHealth.load(old).struck('a/b.mp4'), isTrue);
    });
  });
}
