import 'dart:async';

import 'package:http/http.dart' as http;

import 'archive_client.dart';
import 'file_picker.dart';
import 'models.dart';
import 'probe.dart';
import 'query_builder.dart';

/// Builds a channel's content pool from Archive: search each source, read each
/// item's files, pick one small file per episode/track.
///
/// If the pool's [comprehensible] sound content is less than [ChannelConfig.minContentSeconds],
/// the year range widens back step by step (see [wideningStarts]), stopping as soon as the minimum is
/// met. Items the widening brought in that are silent films are dropped again when the rest suffice.
/// Foreign items without a sidecar are kept (an embedded English track may turn up at play time) but
/// don't count toward the minimum. Sources with `ignoreYear` are unaffected by widening.
///
/// Metadata fetches and faststart probes run at most [concurrency] at a time.
/// With a [probeClient], entries whose mp4 index is not up front are dropped
/// when the rest still fill `minContentSeconds`, else kept (tagged). The result
/// is sorted by [Entry.id], independent of completion order.
Future<List<Entry>> buildPool(
  Channel channel,
  ChannelConfig config,
  ArchiveApi api, {
  int itemsPerSource = 60,
  int concurrency = 4,
  http.Client? probeClient,
  void Function(String message)? log,
  void Function(int done, int total)? onProgress,
}) async {
  if (channel.sources.isEmpty) return []; // e.g. a weatherstar channel without music
  final base = channel.yearRange ?? config.yearRange;

  final metas = <String, ItemMeta?>{}; // each item is fetched once, however often the range widens
  var pool = await _collect(channel, config, api, base, itemsPerSource, concurrency, log, onProgress, metas);
  final baseIds = {for (final e in pool) e.id};
  // Counts toward the minimum: comprehensible, and not a silent film the widening brought in.
  double counted(List<Entry> p) => _total([
        for (final e in p)
          if (comprehensible(e) && (!e.silent || baseIds.contains(e.id))) e,
      ]);
  final widenable = channel.sources.any((s) => !s.ignoreYear); // year-free sources gain nothing from widening
  for (final start in widenable ? wideningStarts(base.start, config.fallbackStart) : const <int>[]) {
    if (counted(pool) >= config.minContentSeconds) break;
    final wide = YearRange(start, base.end);
    log?.call('${channel.name}: thin (${counted(pool) ~/ 60} min), widening to $wide');
    pool = await _collect(channel, config, api, wide, itemsPerSource, concurrency, log, onProgress, metas);
  }
  final noAddedSilent = [
    for (final e in pool)
      if (!e.silent || baseIds.contains(e.id)) e,
  ];
  if (noAddedSilent.length < pool.length && _total(noAddedSilent.where(comprehensible).toList()) >= config.minContentSeconds) {
    pool = noAddedSilent;
  }
  if (probeClient != null) {
    final tagged = List<Entry?>.filled(pool.length, null);
    await forEachLimited(List.generate(pool.length, (i) => i), concurrency, (i) async {
      final f = await probeFaststart(probeClient, pool[i].url);
      tagged[i] = pool[i].copyWith(faststart: f == Faststart.unknown ? null : f == Faststart.yes);
    });
    pool = [for (final e in tagged) e!];
    final kept = pool.where((e) => e.faststart != false).toList();
    if (_total(kept) >= config.minContentSeconds) pool = kept;
  }
  return pool;
}

/// Start years a thin channel widens back to, newest first: [fallbackStart] (1960), 1940, 1920, then
/// no lower limit (1800, before any film), each only if earlier than [start].
List<int> wideningStarts(int start, int fallbackStart) {
  final out = <int>[];
  for (final y in [fallbackStart, 1940, 1920, 1800]) {
    if (y < start && (out.isEmpty || y < out.last)) out.add(y);
  }
  return out;
}

/// An entry a viewer can follow: English or untagged, or foreign with an English sidecar subtitle.
/// (Foreign items with only embedded subtitles are checked when they play.)
bool comprehensible(Entry e) => !e.foreign || e.subUrl != null;

/// Runs [fn] over [items] with at most [limit] in flight (simple worker pool).
Future<void> forEachLimited<T>(Iterable<T> items, int limit, Future<void> Function(T) fn) async {
  final it = items.iterator;
  Future<void> worker() async {
    while (it.moveNext()) {
      await fn(it.current);
    }
  }

  await Future.wait([for (var i = 0; i < (limit < 1 ? 1 : limit); i++) worker()]);
}

double _total(List<Entry> pool) => pool.fold(0.0, (s, e) => s + e.durationSeconds);

Future<List<Entry>> _collect(
  Channel channel,
  ChannelConfig config,
  ArchiveApi api,
  YearRange range,
  int itemsPerSource,
  int concurrency,
  void Function(String)? log,
  void Function(int, int)? onProgress,
  Map<String, ItemMeta?> metas,
) async {
  final seenItems = <String>{};
  final hitsToFetch = <String>[];

  for (final source in channel.sources) {
    final query = buildQuery(source, range: range, blockCollections: config.blockCollections);
    final List<ItemSummary> hits;
    try {
      hits = await api.search(query, rows: itemsPerSource);
    } on ArchiveException catch (e) {
      log?.call('${channel.name}: skip source $query: $e'); // keep what other sources gave
      continue;
    }
    for (final hit in hits) {
      if (config.excludeIdentifiers.contains(hit.identifier)) continue;
      if (seenItems.add(hit.identifier)) hitsToFetch.add(hit.identifier);
    }
  }

  final byId = <String, Entry>{};
  var done = 0;
  await forEachLimited(hitsToFetch, concurrency, (id) async {
    try {
      final meta = metas.containsKey(id) ? metas[id] : metas[id] = await api.metadata(id);
      if (meta != null) {
        for (final e in pickEntries(meta)) {
          byId.putIfAbsent(e.id, () => e);
        }
      }
    } on ArchiveException catch (e) {
      log?.call('skip $id: $e'); // one bad item must not sink the channel
    }
    onProgress?.call(++done, hitsToFetch.length);
  });
  return byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
}
