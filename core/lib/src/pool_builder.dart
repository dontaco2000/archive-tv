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
/// If the pool holds less than [ChannelConfig.minContentSeconds], the year range
/// widens back to [ChannelConfig.fallbackStart] and the pool is rebuilt.
/// Sources with `ignoreYear` are unaffected by widening.
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
  if (channel.type != 'archive') return [];
  final base = channel.yearRange ?? config.yearRange;

  var pool = await _collect(channel, config, api, base, itemsPerSource, concurrency, log, onProgress);
  if (_total(pool) < config.minContentSeconds && base.start > config.fallbackStart) {
    final wide = YearRange(config.fallbackStart, base.end);
    log?.call('${channel.name}: thin (${_total(pool) ~/ 60} min), widening to $wide');
    pool = await _collect(channel, config, api, wide, itemsPerSource, concurrency, log, onProgress);
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
      final meta = await api.metadata(id);
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
