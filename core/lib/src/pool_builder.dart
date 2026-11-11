import 'archive_client.dart';
import 'file_picker.dart';
import 'models.dart';
import 'query_builder.dart';

/// Builds a channel's content pool from Archive: search each source, read each
/// item's files, pick one small file per episode/track.
///
/// If the pool holds less than [ChannelConfig.minContentSeconds], the year range
/// widens back to [ChannelConfig.fallbackStart] and the pool is rebuilt.
/// Sources with `ignoreYear` are unaffected by widening.
Future<List<Entry>> buildPool(
  Channel channel,
  ChannelConfig config,
  ArchiveApi api, {
  int itemsPerSource = 60,
  void Function(String message)? log,
}) async {
  if (channel.type != 'archive') return [];
  final base = channel.yearRange ?? config.yearRange;

  var pool = await _collect(channel, config, api, base, itemsPerSource, log);
  if (_total(pool) < config.minContentSeconds && base.start > config.fallbackStart) {
    final wide = YearRange(config.fallbackStart, base.end);
    log?.call('${channel.name}: thin (${_total(pool) ~/ 60} min), widening to $wide');
    pool = await _collect(channel, config, api, wide, itemsPerSource, log);
  }
  return pool;
}

double _total(List<Entry> pool) => pool.fold(0.0, (s, e) => s + e.durationSeconds);

Future<List<Entry>> _collect(
  Channel channel,
  ChannelConfig config,
  ArchiveApi api,
  YearRange range,
  int itemsPerSource,
  void Function(String)? log,
) async {
  final seenItems = <String>{};
  final byId = <String, Entry>{};

  for (final source in channel.sources) {
    final query = buildQuery(source, range: range, blockCollections: config.blockCollections);
    final hits = await api.search(query, rows: itemsPerSource);
    for (final hit in hits) {
      if (config.excludeIdentifiers.contains(hit.identifier)) continue;
      if (!seenItems.add(hit.identifier)) continue;
      try {
        final meta = await api.metadata(hit.identifier);
        if (meta == null) continue;
        for (final e in pickEntries(meta)) {
          byId.putIfAbsent(e.id, () => e);
        }
      } on ArchiveException catch (e) {
        log?.call('skip ${hit.identifier}: $e'); // one bad item must not sink the channel
      }
    }
  }
  return byId.values.toList();
}
