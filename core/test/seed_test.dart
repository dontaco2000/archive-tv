import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

Entry entry(String item, int i, int minutes) => Entry(
      id: '$item/e$i.mp4',
      itemId: item,
      file: 'e$i.mp4',
      title: '$item $i',
      durationSeconds: minutes * 60.0,
      url: downloadUrl(item, 'e$i.mp4'),
    );

void main() {
  final channel = parseChannelConfig(jsonEncode({
    'channels': [
      {'number': 5, 'name': 'Five', 'sources': [{'collection': 'a'}]},
    ],
  })).channels.single;

  test('trimPool thins evenly over items and leaves small pools alone', () {
    final pool = [for (var i = 0; i < 100; i++) entry('big', i, 60), for (var i = 0; i < 10; i++) entry('small', i, 60)];
    final t = trimPool(channel, pool, 55 * 3600);
    expect(t.length, 55);
    expect(t.where((e) => e.itemId == 'small').length, inInclusiveRange(4, 6)); // keeps its ~9% share
    expect(identical(trimPool(channel, pool, 200 * 3600), pool), isTrue);
  });

  test('compact entries round-trip', () {
    final e = Entry(id: 'x/a b.mp4', itemId: 'x', file: 'a b.mp4', title: 't', durationSeconds: 5, url: downloadUrl('x', 'a b.mp4'), language: 'fre');
    final c = compactEntry(e);
    expect(c.containsKey('url') || c.containsKey('id'), isFalse);
    expect(expandEntry(c).toJson(), e.toJson());
    final odd = Entry(id: 'odd', itemId: 'x', file: 'f', title: 't', durationSeconds: 5, url: 'https://elsewhere/f');
    expect(expandEntry(jsonDecode(jsonEncode(compactEntry(odd))) as Map<String, dynamic>).toJson(), odd.toJson());
  });

  test('installSeed writes missing/older pools once, keeps newer ones', () async {
    final dir = Directory.systemTemp.createTempSync('seed');
    addTearDown(() => dir.deleteSync(recursive: true));
    final at = DateTime(2026, 11, 10);
    List<int> seed() => gzip.encode(utf8.encode([
          jsonEncode({'seed': 1, 'builtAt': at.toIso8601String()}),
          for (final n in [1, 2])
            jsonEncode({
              'n': n,
              'builtAt': at.toIso8601String(),
              'entries': [compactEntry(entry('s$n', 0, 30))],
              'serials': n == 1 ? {'signature': 'x', 'slots': []} : null,
            }),
        ].join('\n')));
    final store = PoolStore(dir);
    store.save(2, [entry('mine', 0, 30)]); // built now: newer than the seed
    expect(await installSeed(Stream.value(seed()), dir), 1);
    expect(store.load(1)!.single.id, 's1/e0.mp4');
    expect(store.age(1)!.inDays, greaterThanOrEqualTo(1));
    expect(File('${dir.path}/serials-1.json').existsSync(), isTrue);
    expect(store.load(2)!.single.itemId, 'mine');
    expect(await installSeed(Stream.value(seed()), dir), 0); // stamp: already installed
  });

  test('installSeed onlyMissing leaves a channel that has any pool alone, even an older one', () async {
    final dir = Directory.systemTemp.createTempSync('seed');
    addTearDown(() => dir.deleteSync(recursive: true));
    final at = DateTime.now();
    final seed = gzip.encode(utf8.encode([
      jsonEncode({'seed': 1, 'builtAt': at.toIso8601String()}),
      for (final n in [1, 2])
        jsonEncode({'n': n, 'builtAt': at.toIso8601String(), 'entries': [compactEntry(entry('s$n', 0, 30))]}),
    ].join('\n')));
    final store = PoolStore(dir);
    store.save(2, [entry('mine', 0, 30)], builtAt: at.subtract(const Duration(days: 3))); // older than the seed
    expect(await installSeed(Stream.value(seed), dir, onlyMissing: true), 1);
    expect(store.load(1)!.single.itemId, 's1');
    expect(store.load(2)!.single.itemId, 'mine');
  });

  test('the shipped seed installs and only has channels from the bundled config', () async {
    final config = parseChannelConfig(File('../player/assets/channels.json').readAsStringSync());
    final dir = Directory.systemTemp.createTempSync('seed');
    addTearDown(() => dir.deleteSync(recursive: true));
    final n = await installSeed(File('../player/assets/seed_pools.jsonl.gz').openRead(), dir);
    final seeded = {
      for (final f in dir.listSync().whereType<File>())
        if (RegExp(r'pool-(\d+)\.json$').firstMatch(f.path) case final m?) int.parse(m[1]!),
    };
    expect(seeded.length, n);
    expect(n, greaterThan(40));
    expect(seeded.difference({for (final c in config.channels) c.number}), isEmpty);
  });
}
