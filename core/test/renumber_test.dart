import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

String sep = Platform.pathSeparator;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('renum'));
  tearDown(() => dir.deleteSync(recursive: true));

  File f(String path) => File('${dir.path}$sep${path.replaceAll('/', sep)}')..parent.createSync(recursive: true);
  String read(String path) => f(path).readAsStringSync();
  List<String> names(String sub) =>
      [for (final x in Directory('${dir.path}$sep$sub').listSync()) x.uri.pathSegments.last]..sort();

  // 33 -> 41 and 41 -> 52 (a chain), 2 <-> 3 (a swap), 5 -> 6 -> 7 -> 5 (a cycle), 9 stays; 23 is not in the map.
  final map = jsonEncode({
    'layout': 2,
    'oldToNew': {'33': 41, '41': 52, '2': 3, '3': 2, '5': 6, '6': 7, '7': 5, '9': 9},
  });

  test('pools, serials and days move to the new numbers (chains, swaps, cycles); unknown numbers are deleted', () {
    for (final n in [33, 41, 2, 3, 5, 6, 7, 9, 23]) {
      f('pools/pool-$n.json').writeAsStringSync('pool of old $n');
      f('days/day-$n-2026-11-13.json').writeAsStringSync('day of old $n');
    }
    f('pools/serials-33.json').writeAsStringSync('serials of old 33');
    f('pools/seed.stamp').writeAsStringSync('2026-11-12');

    expect(migrateLayout(dir, map), contains('17 pool/day files renumbered, 2 of removed channels deleted'));

    expect(read('pools/pool-41.json'), 'pool of old 33');
    expect(read('pools/pool-52.json'), 'pool of old 41');
    expect(read('pools/pool-3.json'), 'pool of old 2');
    expect(read('pools/pool-2.json'), 'pool of old 3');
    expect(read('pools/pool-6.json'), 'pool of old 5');
    expect(read('pools/pool-7.json'), 'pool of old 6');
    expect(read('pools/pool-5.json'), 'pool of old 7');
    expect(read('pools/pool-9.json'), 'pool of old 9');
    expect(read('pools/serials-41.json'), 'serials of old 33');
    expect(read('days/day-41-2026-11-13.json'), 'day of old 33');
    expect(read('days/day-2-2026-11-13.json'), 'day of old 3');
    expect(names('pools'), isNot(contains('pool-23.json')));
    expect(names('pools'), isNot(contains('pool-33.json')));
    expect(names('days'), isNot(contains('day-23-2026-11-13.json')));
    expect(read('pools/seed.stamp'), '2026-11-12');
    expect([...names('pools'), ...names('days')].where((n) => n.endsWith('.renum-tmp')), isEmpty);
    expect(read('layout_version'), '2');

    // Runs once: a second call (next app start) changes nothing.
    f('pools/pool-41.json').writeAsStringSync('new pool 41');
    expect(migrateLayout(dir, map), isNull);
    expect(read('pools/pool-41.json'), 'new pool 41');
  });

  test('settings, wrong-channel lists and the folder channels.json follow the new numbers', () {
    f('settings.json').writeAsStringSync(jsonEncode({
      'favorites': [2, 33, 23],
      'lastChannel': 33,
      'volume': 40,
      'parental': {'locked': [5, 7, 23], 'lockOn': true},
    }));
    f('wrong_items.json').writeAsStringSync(jsonEncode({'33': ['a'], '23': ['b'], '2': ['c']}));
    f('wrong_channel.jsonl').writeAsStringSync('${jsonEncode({'channel': 33, 'item': 'a'})}\nnot json\n');
    f('channels.json').writeAsStringSync('old config');
    f('channels.bundled.json').writeAsStringSync('old bundle');

    migrateLayout(dir, map);

    final s = jsonDecode(read('settings.json')) as Map<String, dynamic>;
    expect(s['favorites'], [3, 41]); // 23 is gone
    expect(s['lastChannel'], 41);
    expect(s['volume'], 40);
    expect(s['parental'], {'locked': [5, 6], 'lockOn': true});
    expect(jsonDecode(read('wrong_items.json')), {
      '41': ['a'],
      '3': ['c'],
    });
    expect(read('wrong_channel.jsonl'), '${jsonEncode({'channel': 41, 'item': 'a'})}\nnot json\n');
    expect(f('channels.json').existsSync(), isFalse);
    expect(f('channels.bundled.json').existsSync(), isFalse);
    expect(read('channels.json.pre-renumber'), 'old config');
  });

  test('a removed last channel becomes null; a fresh folder just gets the marker', () {
    f('settings.json').writeAsStringSync(jsonEncode({'lastChannel': 23}));
    migrateLayout(dir, map);
    expect((jsonDecode(read('settings.json')) as Map)['lastChannel'], isNull);

    final fresh = Directory('${dir.path}${sep}fresh');
    expect(migrateLayout(fresh, map), isNotNull);
    expect(File('${fresh.path}${sep}layout_version').readAsStringSync(), '2');
  });

  test('a crash in phase 1 redoes phase 1 without mapping anything twice', () {
    // State after a crash part-way through phase 1: old 33 already moved (as 41 + suffix), old 41 not yet.
    f('pools/pool-41.json.renum-tmp').writeAsStringSync('pool of old 33');
    f('pools/pool-41.json').writeAsStringSync('pool of old 41');
    f('settings.json').writeAsStringSync(jsonEncode({'lastChannel': 33}));
    f('settings.json.renum-tmp').writeAsStringSync('half'); // rewritten from the untouched original
    migrateLayout(dir, map);
    expect(read('pools/pool-41.json'), 'pool of old 33');
    expect(read('pools/pool-52.json'), 'pool of old 41');
    expect((jsonDecode(read('settings.json')) as Map)['lastChannel'], 41);
  });

  test('a crash in phase 2 only finishes the renames', () {
    // Phase 1 done (pending written), one rename already done: the done one must not be mapped again.
    f('layout_version.pending').writeAsStringSync('2');
    f('pools/pool-41.json').writeAsStringSync('pool of old 33'); // already renamed
    f('pools/pool-52.json.renum-tmp').writeAsStringSync('pool of old 41');
    f('settings.json').writeAsStringSync(jsonEncode({'lastChannel': 41})); // already mapped
    migrateLayout(dir, map);
    expect(read('pools/pool-41.json'), 'pool of old 33');
    expect(read('pools/pool-52.json'), 'pool of old 41');
    expect((jsonDecode(read('settings.json')) as Map)['lastChannel'], 41);
    expect(f('layout_version.pending').existsSync(), isFalse);
  });

  group('bundled layout', () {
    final config = parseChannelConfig(File('../player/assets/channels.json').readAsStringSync());
    final bundled = jsonDecode(File('../player/assets/renumber_map.json').readAsStringSync()) as Map<String, dynamic>;
    // Layout 5 blocks (inclusive).
    const blocks = {
      'Kids & Animation': (2, 9),
      'Movies': (10, 21),
      'Comedy & Variety': (22, 35),
      'Drama & Classic TV': (36, 47),
      'News & Docs': (48, 58),
      'Music': (59, 64),
      'Sports': (65, 76),
      'World & Lifestyle': (77, 90),
    };

    test('numbers are unique, in order, and each channel sits in its genre\'s block', () {
      final numbers = [for (final c in config.channels) c.number];
      expect(numbers.toSet(), hasLength(numbers.length));
      expect(numbers, [...numbers]..sort());
      for (final c in config.channels) {
        final (lo, hi) = blocks[c.genre]!;
        expect(c.number >= lo && c.number <= hi, isTrue, reason: '${c.number} ${c.name} (${c.genre})');
      }
    });

    test('renumber_map.json is one-to-one and lands on the channel numbers; only the new layout-5 channels are unmapped', () {
      final values = (bundled['oldToNew'] as Map).values.cast<int>().toList();
      expect(values.toSet(), hasLength(values.length));
      final numbers = {for (final c in config.channels) c.number};
      expect(numbers.containsAll(values), isTrue);
      // added in layout 5: Syndi-Toons, Starbase, Cliffhanger, Afterhours, Date-Night, Anthology, Filmstrip, VJ; plus Regen (47, Doctor Who, layout-5 spare)
      expect(numbers.difference(values.toSet()), {4, 14, 19, 26, 30, 37, 47, 51, 61});
      final keys = (bundled['oldToNew'] as Map).keys.map((k) => int.parse(k as String)).toSet();
      expect(keys, hasLength(72)); // every layout-4 channel, no temporary numbers (80-87)
      expect(keys.where((n) => n > 75), isEmpty);
      expect(bundled['layout'], 5);
    });

    test('layout 4 -> 5 sample: data moves with its channel, nothing lands on a new channel', () {
      final m = jsonEncode(bundled);
      // layout 4: 4 Sakura, 13 Warp, 14 Haunt, 23 Nightcap, 27 Winners, 42 Cumulus, 50 Twang, 53 Boogie, 64 Overseas, 75 Telly
      for (final n in [2, 4, 13, 14, 23, 27, 42, 50, 53, 64, 75]) {
        f('pools/pool-$n.json').writeAsStringSync('pool of old $n');
        f('days/day-$n-2026-11-19.json').writeAsStringSync('day of old $n');
      }
      f('layout_version').writeAsStringSync('4');
      f('settings.json').writeAsStringSync(jsonEncode({
        'favorites': [42, 75, 53],
        'lastChannel': 50,
        'parental': {'locked': [27, 64], 'lockOn': true},
      }));
      f('wrong_items.json').writeAsStringSync(jsonEncode({'64': ['a']}));
      f('wrong_channel.jsonl').writeAsStringSync('${jsonEncode({'channel': 23, 'item': 'b'})}\n');

      expect(migrateLayout(dir, m), contains('22 pool/day files renumbered, 0 of removed channels deleted'));
      for (final (o, n) in [(2, 2), (4, 5), (13, 13), (14, 15), (23, 25), (27, 31), (42, 49), (50, 59), (53, 63), (64, 77), (75, 88)]) {
        expect(read('pools/pool-$n.json'), 'pool of old $o');
        expect(read('days/day-$n-2026-11-19.json'), 'day of old $o');
        expect(config.channel(n), isNotNull);
      }
      expect(config.channel(13)!.name, 'Warp');
      expect(config.channel(49)!.name, 'Cumulus');
      for (final n in [4, 14, 19, 26, 30, 37, 51, 61]) {
        expect(f('pools/pool-$n.json').existsSync(), isFalse, reason: 'new channel $n starts empty');
      }
      final s = jsonDecode(read('settings.json')) as Map<String, dynamic>;
      expect(s['favorites'], [49, 63, 88]);
      expect(s['lastChannel'], 59);
      expect(s['parental'], {'locked': [31, 77], 'lockOn': true});
      expect(jsonDecode(read('wrong_items.json')), {'77': ['a']});
      expect(jsonDecode(read('wrong_channel.jsonl').trim()), {'channel': 25, 'item': 'b'});
      expect(read('layout_version'), '5');
      expect(migrateLayout(dir, m), isNull);
    });

    test('the seed is keyed by the new numbers and names', () {
      final lines = utf8
          .decode(gzip.decode(File('../player/assets/seed_pools.jsonl.gz').readAsBytesSync()))
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .skip(1);
      for (final l in lines) {
        final j = jsonDecode(l) as Map<String, dynamic>;
        expect(config.channel(j['n'] as int)?.name, j['name']);
      }
    });
  
  test('non-object JSON in settings/wrong_items does not abort the move or repeat it', () {
    f('settings.json').writeAsStringSync('null');
    f('wrong_items.json').writeAsStringSync('[]');
    f('pools/pool-2.json').writeAsStringSync('old 2');
    expect(migrateLayout(dir, map), contains('1 pool/day files renumbered'));
    expect(read('pools/pool-3.json'), 'old 2');
    expect(read('layout_version'), '2');
    f('pools/pool-3.json').writeAsStringSync('new 3');
    expect(migrateLayout(dir, map), isNull);
    expect(read('pools/pool-3.json'), 'new 3');
  });

  test('a locked-file failure still moves settings to the new numbers and writes layout_version atomically', () {
    f('settings.json').writeAsStringSync(jsonEncode({'favorites': [2], 'lastChannel': 2, 'parental': {'locked': [2], 'lockOn': true}}));
    f('pools/pool-2.json').writeAsStringSync('old 2');
    f('pools/pool-9.json').writeAsStringSync('old 9');
    // a non-empty directory where pool-2 must be renamed to makes the rename throw FileSystemException
    f('pools/pool-3.json.renum-tmp/x').writeAsStringSync('block');
    final log = migrateLayout(dir, map)!;
    expect(log, contains('migration failed'));
    final s = jsonDecode(read('settings.json')) as Map<String, dynamic>;
    expect(s['favorites'], [3]);
    expect(s['lastChannel'], 3);
    expect(s['parental'], {'locked': [3], 'lockOn': true});
    expect(Directory('${dir.path}${sep}pools').existsSync(), isFalse);
    expect(read('layout_version'), '2');
    expect(File('${dir.path}${sep}layout_version.tmp').existsSync(), isFalse);
    expect(dir.listSync().whereType<File>().where((x) => x.path.endsWith('.renum-tmp')), isEmpty);
    expect(migrateLayout(dir, map), isNull);
  });
});
}
