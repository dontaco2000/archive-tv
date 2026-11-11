import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:path/path.dart' as p;

/// What is on a channel at one moment: the slot, how far into it we are, and what follows.
class Airing {
  final Channel channel;
  final Slot slot;
  final double offsetSeconds;
  final Slot? next;

  const Airing(this.channel, this.slot, this.offsetSeconds, this.next);

  Duration get remaining => slot.end.difference(slot.start) - Duration(milliseconds: (offsetSeconds * 1000).round());
}

/// Ties the core package together for the player: config, pools on disk,
/// saved day schedules, blocklist. One instance per app run.
class TvEngine {
  final ChannelConfig config;
  final ArchiveApi api;
  final PoolStore pools;
  final SnapshotStore snapshots;
  final Blocklist blocklist;
  final void Function(String) log;
  final Map<int, List<Entry>> _pool = {};

  TvEngine._(this.config, this.api, this.pools, this.snapshots, this.blocklist, this.log);

  /// [configText] is the contents of channels.json; [dataDir] holds pools, snapshots, blocklist.
  factory TvEngine.open({
    required String configText,
    required Directory dataDir,
    ArchiveApi? api,
    void Function(String)? log,
  }) {
    return TvEngine._(
      parseChannelConfig(configText),
      api ?? ArchiveClient(),
      PoolStore(Directory(p.join(dataDir.path, 'pools'))),
      SnapshotStore(Directory(p.join(dataDir.path, 'days'))),
      Blocklist.load(dataDir),
      log ?? (_) {},
    );
  }

  List<Channel> get channels => config.channels;

  /// Channels that can be tuned now: archive channels whose pool has enough content.
  /// Call [ensurePool] first for channels you want considered.
  List<Channel> get tunable => [
        for (final c in config.channels)
          if (c.type == 'archive' && _pool.containsKey(c.number) && !isOffAir(_pool[c.number]!, config.minContentSeconds)) c,
      ];

  final Map<int, Future<void>> _building = {};

  /// Loads the channel's pool from disk, or builds it from Archive when missing or older than a day.
  /// Concurrent callers for the same channel share one build.
  /// [maxAge] zero forces a rebuild even when the pool is already loaded (menu "Refresh channels").
  Future<void> ensurePool(Channel channel, {Duration maxAge = const Duration(days: 1)}) {
    if (channel.type != 'archive' || (maxAge > Duration.zero && _pool.containsKey(channel.number))) return Future.value();
    return _building[channel.number] ??= _ensurePool(channel, maxAge).whenComplete(() {
      _building.remove(channel.number);
    });
  }

  Future<void> _ensurePool(Channel channel, Duration maxAge) async {
    final saved = pools.load(channel.number);
    final age = pools.age(channel.number);
    if (saved != null && age != null && age < maxAge) {
      _pool[channel.number] = blocklist.apply(saved);
      return;
    }
    try {
      final built = await buildPool(channel, config, api, log: log);
      if (built.isEmpty) {
        // buildPool logs failed searches and returns what it has; an empty result means
        // the refresh failed. Never save it; keep the pool we already had, if any.
        log('${channel.name}: build found nothing${saved != null ? ', keeping the saved pool' : ''}');
        if (saved != null) _pool[channel.number] = blocklist.apply(saved);
        return;
      }
      pools.save(channel.number, built);
      _pool[channel.number] = blocklist.apply(built);
    } on Object catch (e) {
      log('pool build failed for ${channel.name}: $e'); // fall back to a stale pool if there is one
      if (saved != null) _pool[channel.number] = blocklist.apply(saved);
    }
  }

  final Blocklist _skipped = Blocklist.session(); // items that failed to play this run

  /// Drops [entryId] from [channel]'s schedule for this session (nothing saved);
  /// the next [airing]/[guideFor] re-lays the day out without it.
  void markBad(Channel channel, String entryId) {
    log('${channel.name}: skipping $entryId for this session');
    _skipped.add(entryId);
  }

  List<Slot> _day(Channel c, DateTime day) => snapshots.day(c.number, day, _pool[c.number] ?? const [],
      blocklist: _skipped.ids.isEmpty ? blocklist : blocklist.union(_skipped));

  /// What is airing on [channel] at [now], or null if it has no content.
  Airing? airing(Channel channel, DateTime now) {
    final today = _day(channel, now);
    final slot = slotAt(today, now);
    if (slot == null) return null;
    final i = today.indexOf(slot);
    final next = i + 1 < today.length ? today[i + 1] : slotAt(_day(channel, DateTime(now.year, now.month, now.day + 1)), DateTime(now.year, now.month, now.day + 1));
    return Airing(channel, slot, offsetSeconds(slot, now), next);
  }

  /// The rolling guide for [channel]: slots overlapping the next [hours] hours.
  List<Slot> guideFor(Channel channel, DateTime now, {int hours = 12}) =>
      guide(now, (d) => _day(channel, d), hours: hours);

  /// Keeps saved days current: today plus six more, then deletes past days.
  void planWeek(Channel channel, DateTime now) {
    snapshots.ensureWeek(channel.number, now, _pool[channel.number] ?? const []);
    snapshots.prune(now);
  }
}
