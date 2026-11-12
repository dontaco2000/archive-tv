// Builds the Android seed pools (see lib/src/seed.dart) from Archive, like the app does on first run.
// Run before each APK build, from app\core:
//   dart run tool/make_seed_pools.dart ../player/assets/channels.json ../player/assets/seed_pools.jsonl.gz [maxHours=150]
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: make_seed_pools.dart <channels.json> <out.jsonl.gz> [maxHours]');
    exit(2);
  }
  final config = parseChannelConfig(File(args[0]).readAsStringSync());
  final maxSeconds = (args.length > 2 ? double.parse(args[2]) : 150.0) * 3600;
  final api = ArchiveClient();
  final builtAt = DateTime.now().toIso8601String();
  final lines = <String>[jsonEncode({'seed': 1, 'builtAt': builtAt})];
  final sw = Stopwatch()..start();
  for (final c in config.channels) {
    if (c.sources.isEmpty) continue;
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
    double h(List<Entry> l) => l.fold(0.0, (s, e) => s + e.durationSeconds) / 3600;
    stdout.writeln('${c.number} ${c.name}: ${pool.length} entries ${h(pool).round()} h -> '
        '${trimmed.length} entries ${h(trimmed).round()} h (${sw.elapsed.inSeconds} s)');
  }
  api.close();
  final raw = utf8.encode('${lines.join('\n')}\n');
  final gz = gzip.encode(raw);
  File(args[1]).writeAsBytesSync(gz);
  stdout.writeln('${lines.length - 1} channels, ${raw.length} bytes JSON, ${gz.length} bytes gzip -> ${args[1]}');
}
