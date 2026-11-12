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

  // Each item is fetched once, however often the range widens. Only its picked entries are kept (not the item's
  // whole file list, thousands of files for big packs) to stay light on 1 GB devices.
  final metas = <String, List<Entry>>{};
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

double _minSeconds(Channel c) => (c.minSeconds ?? (c.shortContent != null ? 60 : 120)).toDouble();

/// Whether [e] passes the CURRENT config's cheap (no network) filters for [c]: its item is not in
/// [ChannelConfig.excludeIdentifiers] and its length is within the channel's minimum and what its sources allow
/// (the largest source `maxSeconds` when every source sets one, else 6 h). Used on pools and days saved by an
/// older config (app update). [ChannelConfig.blockCollections] can't be checked here (entries don't carry
/// collections); the next rebuild drops those.
bool Function(Entry) poolFilter(Channel c, ChannelConfig config) {
  final minS = _minSeconds(c);
  final caps = [for (final s in c.sources) s.maxSeconds];
  final maxS = caps.isEmpty || caps.contains(null) ? 6 * 3600 : caps.cast<int>().reduce((a, b) => a > b ? a : b);
  return (e) => !_excluded(config, e) && e.durationSeconds >= minS && e.durationSeconds <= maxS;
}

/// An excludeIdentifiers entry is an item id, or an entry id (`item/file`) to drop one file of a good item.
bool _excluded(ChannelConfig config, Entry e) =>
    config.excludeIdentifiers.contains(e.itemId) || config.excludeIdentifiers.contains(e.id);

/// [pool] cut by [poolFilter]; [pool] itself when nothing is dropped.
List<Entry> refilterPool(Channel c, ChannelConfig config, List<Entry> pool) {
  final ok = poolFilter(c, config);
  return pool.every(ok) ? pool : pool.where(ok).toList();
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
  Map<String, List<Entry>> metas,
) async {
  final sourceOf = <String, Source>{}; // item -> the first source that found it
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
      if (sourceOf.containsKey(hit.identifier)) continue;
      sourceOf[hit.identifier] = source;
      hitsToFetch.add(hit.identifier);
    }
  }

  final byId = <String, Entry>{};
  var done = 0;
  await forEachLimited(hitsToFetch, concurrency, (id) async {
    try {
      final maxS = sourceOf[id]?.maxSeconds;
      final key = '$id|$maxS'; // the picks depend on the finding source's maxSeconds
      var picks = metas[key];
      if (picks == null) {
        final meta = await api.metadata(id);
        picks = metas[key] = meta == null
            ? const []
            : pickEntries(meta,
                minSeconds: _minSeconds(channel),
                maxSeconds: maxS == null ? 6 * 3600 : maxS.toDouble());
      }
      for (final e in picks) {
        if (!_excluded(config, e)) byId.putIfAbsent(e.id, () => e);
      }
    } on ArchiveException catch (e) {
      log?.call('skip $id: $e'); // one bad item must not sink the channel
    }
    onProgress?.call(++done, hitsToFetch.length);
  });
  final all = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  // Tag entries of sources the scheduler/guide treat specially (perDay, blockLabel) with their source index.
  return [
    for (final e in capPerSource(all, (e) => sourceOf[e.itemId]))
      if (sourceOf[e.itemId] case final s? when s.perDay != null || s.blockLabel != null)
        e.copyWith(source: channel.sources.indexOf(s))
      else
        e,
  ];
}

/// Applies each source's caps. [Source.maxEntriesPerItem] first thins every item of the source to at most that many
/// entries, evenly spaced over the item's files (so a 1,000-episode pack keeps all its seasons). Then
/// [Source.maxEntries] takes the source's entries round-robin over its items (one per item per round, in id order)
/// until the cap, so a source's small items all stay and a huge pack only fills the rest. Order of [pool] is kept.
List<Entry> capPerSource(List<Entry> pool, Source? Function(Entry) sourceOf) {
  final bySource = <Source, Map<String, List<Entry>>>{};
  for (final e in pool) {
    final s = sourceOf(e);
    if (s != null && (s.maxEntries != null || s.maxEntriesPerItem != null)) ((bySource[s] ??= {})[e.itemId] ??= []).add(e);
  }
  final drop = <Entry>{};
  bySource.forEach((s, byItem) {
    final per = s.maxEntriesPerItem;
    final lists = [
      for (final l in byItem.values) per == null || l.length <= per ? l : [for (var i = 0; i < per; i++) l[i * l.length ~/ per]],
    ];
    final keep = <Entry>{};
    final max = s.maxEntries ?? pool.length;
    final queues = [for (final l in lists) l.iterator];
    while (keep.length < max && queues.isNotEmpty) {
      queues.removeWhere((q) {
        if (keep.length >= max || !q.moveNext()) return true;
        keep.add(q.current);
        return false;
      });
    }
    for (final l in byItem.values) {
      drop.addAll(l.where((e) => !keep.contains(e)));
    }
  });
  return drop.isEmpty ? pool : [for (final e in pool) if (!drop.contains(e)) e];
}
