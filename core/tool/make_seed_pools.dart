// Builds the Android seed pools (see lib/src/seed.dart) from Archive, like the app does on first run.
// Run before each APK build, from app\core:
//   dart run tool/make_seed_pools.dart ../player/assets/channels.json ../player/assets/seed_pools.jsonl.gz [maxHours=150]
// Rebuild only some channels in the existing seed (other channels' lines are kept as they are):
//   dart run tool/make_seed_pools.dart ../player/assets/channels.json ../player/assets/seed_pools.jsonl.gz --only=11,20
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

Future<void> main(List<String> argv) async {
  final only = argv.where((a) => a.startsWith('--only=')).map((a) => a.substring(7).split(',').map(int.parse).toSet()).firstOrNull;
  final args = argv.where((a) => !a.startsWith('--')).toList();
  if (args.length < 2) {
    stderr.writeln('usage: make_seed_pools.dart <channels.json> <out.jsonl.gz> [maxHours] [--only=n,n]');
    exit(2);
  }
  final config = parseChannelConfig(File(args[0]).readAsStringSync());
  final maxSeconds = (args.length > 2 ? double.parse(args[2]) : 150.0) * 3600;
  final api = ArchiveClient();
  final builtAt = DateTime.now().toIso8601String();
  final lines = <String>[jsonEncode({'seed': 1, 'builtAt': builtAt})];
  final old = <int, String>{};
  if (only != null) {
    final kept = utf8.decode(gzip.decode(File(args[1]).readAsBytesSync())).split('\n').where((l) => l.trim().isNotEmpty).toList();
    for (final l in kept.skip(1)) { // new header so installed apps re-check; kept lines keep their own builtAt
      old[(jsonDecode(l) as Map)['n'] as int] = l;
    }
  }
  final sw = Stopwatch()..start();
  for (final c in config.channels) {
    if (c.sources.isEmpty) continue;
    if (only != null && !only.contains(c.number)) {
      if (old[c.number] case final l?) lines.add(l);
      continue;
    }
    final pool = await buildPool(c, config, api, log: (m) => stderr.writeln('  $m'));
    if (pool.isEmpty) {
      stderr.writeln('${c.number} ${c.name}: EMPTY, not seeded');
      continue;
    }
    final trimmed = trimPool(c, pool, maxSeconds);
    List<List<List<Entry>>>? eps;
    if (c.serials.isNotEmpty) eps = await buildSerialEpisodes(c, api, log: (m) => stderr.writeln('  $m'));
    lines.add(jsonEncode({
      'n': c.number,
      'name': c.name, // _build\renumber\renumber.py maps seed lines by name
      'builtAt': builtAt,
      'entries': [for (final e in trimmed) compactEntry(e)],
      'serials': eps == null
          ? null
          : {
              'signature': serialsSignature(c),
              'slots': [
                for (final slot in eps) [for (final show in slot) [for (final e in show) e.toJson()]],
              ],
            },
    }));
    double h(Iterable<Entry> l) => l.fold(0.0, (s, e) => s + e.durationSeconds) / 3600;
    final byItem = <String, List<Entry>>{};
    for (final e in pool.where((e) => !isRare(c, e))) {
      (byItem[e.itemId] ??= []).add(e);
    }
    final top = byItem.entries.toList()..sort((a, b) => h(b.value).compareTo(h(a.value)));
    final all = h(pool.where((e) => !isRare(c, e)));
    stdout.writeln('${c.number} ${c.name}: ${pool.length} entries ${h(pool).round()} h -> '
        '${trimmed.length} entries ${h(trimmed).round()} h (${sw.elapsed.inSeconds} s); top items: '
        '${top.take(3).map((t) => '${t.key} ${(100 * h(t.value) / all).toStringAsFixed(1)}% (${t.value.length})').join(', ')}');
  }
  api.close();
  final raw = utf8.encode('${lines.join('\n')}\n');
  final gz = gzip.encode(raw);
  File(args[1]).writeAsBytesSync(gz);
  stdout.writeln('${lines.length - 1} channels, ${raw.length} bytes JSON, ${gz.length} bytes gzip -> ${args[1]}');
}
