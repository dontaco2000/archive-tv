// How On Demand groups real pools into shows, per genre (dev check for the grouping heuristics).
// dart run tool/ondemand_shows.dart <channels.json> <seed_pools.jsonl.gz | pools folder> [item_info.json] [--list=Genre]
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

void main(List<String> args) {
  final list = args.where((a) => a.startsWith('--list=')).map((a) => a.substring(7)).firstOrNull;
  final pos = args.where((a) => !a.startsWith('--')).toList();
  final config = parseChannelConfig(File(pos[0]).readAsStringSync());
  final pools = <int, List<Entry>>{};
  if (pos[1].endsWith('.gz')) {
    for (final line in const LineSplitter().convert(utf8.decode(gzip.decode(File(pos[1]).readAsBytesSync())))) {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['n'] case final int n) pools[n] = [for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) expandEntry(e)];
    }
  } else {
    for (final c in config.channels) {
      final f = File('${pos[1]}/pool-${c.number}.json');
      if (!f.existsSync()) continue;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      pools[c.number] = [for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) Entry.fromJson(e)];
    }
  }
  final info = pos.length > 2 ? ItemInfoStore(File(pos[2])) : null;
  final genres = {for (final c in config.channels) if (c.type == 'archive' && pools.containsKey(c.number)) c.genre};
  print('| Genre | entries | shows | Movies & specials | biggest shows |');
  print('|---|---|---|---|---|');
  for (final g in genres) {
    final entries = [for (final c in config.channels) if (c.genre == g) ...?pools[c.number]];
    final sw = Stopwatch()..start();
    final l = groupShows(entries, itemInfo: info == null ? null : (id) => info[id]);
    final ms = sw.elapsedMilliseconds;
    final big = [...l.shows]..sort((a, b) => b.entries.length.compareTo(a.entries.length));
    print('| $g | ${entries.length} | ${l.shows.length} | ${l.singles.length} | '
        '${big.take(5).map((s) => '${s.name} ${s.entries.length}').join(', ')} | ($ms ms)');
    if (g == list) {
      for (final s in l.shows) {
        print('  SHOW ${s.name} (${s.entries.length}): ${s.entries.take(3).map((e) => e.title).join(' / ')}');
      }
      for (final e in l.singles) {
        print('  SINGLE ${e.title}  [${e.itemId}]');
      }
    }
  }
}
