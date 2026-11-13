// Runs programme-title enrichment over a pools folder and prints before/after examples.
//
//   dart run tool/enrich_titles.dart <pools folder> [--cache=<item_info.json>] [--fetch] [--all] [--limit=N] [--examples=N]
//
// Without --fetch only the cache is used (offline). --fetch looks up the items that need it (or every item with
// --all) on archive.org, 2 batches at a time, and saves them to the cache (default: item_info.json next to the
// pools folder, the app's data folder). --limit caps how many items are fetched (smoke tests).
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

Future<void> main(List<String> args) async {
  String? opt(String name) => args.where((a) => a.startsWith('--$name=')).map((a) => a.split('=').skip(1).join('=')).firstOrNull;
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.isEmpty) {
    stderr.writeln('usage: dart run tool/enrich_titles.dart <pools folder> [--cache=file] [--fetch] [--all] [--limit=N] [--examples=N]');
    exit(64);
  }
  final pools = Directory(positional.first);
  final cache = File(opt('cache') ?? '${pools.parent.path}${Platform.pathSeparator}item_info.json');
  final examples = int.tryParse(opt('examples') ?? '') ?? 3;
  final limit = int.tryParse(opt('limit') ?? '');
  final client = ArchiveClient();
  final store = ItemInfoStore(cache, fetch: args.contains('--fetch') ? client.itemInfos : null, log: print);

  final byChannel = <String, List<Entry>>{};
  for (final f in pools.listSync().whereType<File>().where((f) => RegExp(r'pool-\d+\.json$').hasMatch(f.path))) {
    final n = int.parse(RegExp(r'pool-(\d+)\.json$').firstMatch(f.path)![1]!);
    final entries = PoolStore(pools).load(n);
    if (entries != null) byChannel['$n'] = entries;
  }
  final all = [for (final l in byChannel.values) ...l];
  final items = {for (final e in all) e.itemId};
  final needing = all.where(needsItemInfo).toList();
  final uninformative = all.where((e) => !titleIsInformative(cleanTitle(e.title))).toList();
  print('${byChannel.length} pools, ${all.length} entries, ${items.length} items');
  print('entries needing item info: ${needing.length} (${{for (final e in needing) e.itemId}.length} items); '
      'uninformative: ${uninformative.length} (${{for (final e in uninformative) e.itemId}.length} items)');
  print('cache: ${cache.path} (${store.length} items)');

  if (args.contains('--fetch')) {
    final sw = Stopwatch()..start();
    var source = args.contains('--all') ? all : needing;
    if (limit != null) {
      final keep = {for (final e in source) e.itemId}.take(limit).toSet();
      source = [for (final e in source) if (keep.contains(e.itemId)) e];
    }
    final added = await store.enrich(source, all: args.contains('--all'));
    print('fetched $added items in ${sw.elapsed.inSeconds} s; cache now ${store.length} items, ${cache.existsSync() ? cache.lengthSync() : 0} bytes');
  }
  client.close();

  print('\nBEFORE -> AFTER (channel: raw title -> guide label | description)');
  for (final MapEntry(key: ch, value: entries) in byChannel.entries.toList()..sort((a, b) => int.parse(a.key) - int.parse(b.key))) {
    final seen = <String>{};
    final picks = [for (final e in entries) if (needsItemInfo(e) && seen.add(e.itemId)) e].take(examples);
    for (final e in picks) {
      final info = store.info(e);
      final desc = info.description == null ? '' : ' | ${info.description!.length > 80 ? '${info.description!.substring(0, 80)}...' : info.description}';
      print('ch $ch: "${e.title}" -> "${info.label}"$desc   [${e.itemId}]');
    }
  }
}
