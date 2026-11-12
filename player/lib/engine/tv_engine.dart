import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;
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

  /// Files found slow to start (mp4 index at the end), kept out of schedules; saved as slow.json.
  final Blocklist slow;

  /// Foreign-language files found at play time to have no English subtitles; kept out of schedules
  /// and On Demand for good; saved as nosubs.json.
  final Blocklist noSubs;

  /// Probes upcoming files after each fresh pool build; null turns probing off (tests).
  final http.Client? probeClient;
  final void Function(String) log;
  final Map<int, List<Entry>> _pool = {};

  TvEngine._(this.config, this.api, this.pools, this.snapshots, this.blocklist, this.slow, this.noSubs, this.probeClient,
      this.log);

  /// [configText] is the contents of channels.json; [dataDir] holds pools, snapshots, blocklist.
  factory TvEngine.open({
    required String configText,
    required Directory dataDir,
    ArchiveApi? api,
    http.Client? probeClient,
    void Function(String)? log,
  }) {
    return TvEngine._(
      parseChannelConfig(configText),
      api ?? ArchiveClient(),
      PoolStore(Directory(p.join(dataDir.path, 'pools'))),
      SnapshotStore(Directory(p.join(dataDir.path, 'days'))),
      Blocklist.load(dataDir),
      Blocklist.load(dataDir, name: 'slow.json'),
      Blocklist.load(dataDir, name: 'nosubs.json'),
      probeClient,
      log ?? (_) {},
    );
  }

  List<Channel> get channels => config.channels;

  /// The channel's loaded pool (blocked and no-subtitle items removed); empty if not loaded.
  List<Entry> poolOf(Channel c) => noSubs.apply(_pool[c.number] ?? const []);

  /// [e] as the current pool has it: a day saved from an older pool lacks newer fields (language, subtitles).
  Entry fresh(Channel c, Entry e) => _pool[c.number]?.where((p) => p.id == e.id).firstOrNull ?? e;

  /// Channels that can be tuned now: archive channels whose pool has enough content,
  /// plus weather channels (always on; their music is optional).
  /// Call [ensurePool] first for channels you want considered.
  List<Channel> get tunable => [
        for (final c in config.channels)
          if (c.type == 'weatherstar' ||
              (_pool.containsKey(c.number) && !isOffAir(poolOf(c), config.minContentSeconds)))
            c,
      ];

  final Map<int, Future<void>> _building = {};

  /// Loads the channel's pool from disk, or builds it from Archive when missing or older than a day.
  /// Concurrent callers for the same channel share one build.
  /// [maxAge] zero forces a rebuild even when the pool is already loaded (menu "Refresh channels").
  Future<void> ensurePool(Channel channel, {Duration maxAge = const Duration(days: 1)}) {
    if (channel.sources.isEmpty || (maxAge > Duration.zero && _pool.containsKey(channel.number))) return Future.value();
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
      _queueProbe(channel);
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

  /// Remembers for good that foreign-language [entryId] has no English subtitles: it leaves today's
  /// schedule now and every later day and pool.
  void markNoSubs(Channel channel, String entryId) {
    log('${channel.name}: $entryId has no English subtitles, dropped for good');
    noSubs.add(entryId);
  }

  List<Slot> _day(Channel c, DateTime day) => snapshots.day(c.number, day, _pool[c.number] ?? const [],
      blocklist: blocklist.union(_skipped).union(slow).union(noSubs));

  Future<void> _probing = Future.value();

  /// Background probe after a fresh build, one channel at a time.
  void _queueProbe(Channel c) {
    final client = probeClient;
    if (client == null || c.type != 'archive') return; // the probe reads mp4 boxes; weather music is mp3
    _probing = _probing.then((_) async {
      try {
        await probeUpcoming(c, DateTime.now(), client);
      } on Object catch (e) {
        log('probe ${c.name} failed: $e');
      }
    });
  }

  /// Probes the files due to air on [c] in the next 12 hours (not the one airing at [now])
  /// and moves slow-start ones into [slow], unless that would leave the channel too thin.
  /// ponytail: only the upcoming window is probed: whole pools are ~27k files (hours of
  /// requests); later files get their turn at the next daily refresh. Returns how many were slow.
  Future<int> probeUpcoming(Channel c, DateTime now, http.Client client, {int concurrency = 6}) async {
    final seen = <String>{};
    final todo = [
      for (final s in guideFor(c, now))
        if (s.start.isAfter(now) && seen.add(s.entry.id)) s.entry,
    ];
    final bad = <Entry>[];
    await forEachLimited(todo, concurrency, (e) async {
      if (await probeFaststart(client, e.url) == Faststart.no) bad.add(e);
    });
    final badIds = {for (final e in bad) e.id};
    final left = (_pool[c.number] ?? const <Entry>[]).where((e) => !badIds.contains(e.id) && !slow.ids.contains(e.id));
    if (bad.isNotEmpty && !isOffAir(left.toList(), config.minContentSeconds)) {
      for (final id in badIds) {
        slow.add(id);
      }
    }
    log('${c.name}: probed ${todo.length} upcoming, ${bad.length} slow to start');
    return bad.length;
  }

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

  /// The once-a-day job (launch and each local midnight): rebuilds pools older than [maxAge],
  /// saves the new week's days, deletes past ones and probes the next 12 hours of every channel.
  Future<void> dailyRefresh(DateTime now, {Duration maxAge = const Duration(days: 1)}) async {
    for (final c in channels) {
      if (c.sources.isEmpty) continue;
      final age = pools.age(c.number);
      final stale = age == null || age >= maxAge;
      try {
        await ensurePool(c, maxAge: stale ? Duration.zero : maxAge);
      } on Object catch (e) {
        log('daily refresh ${c.name}: $e');
      }
      planWeek(c, now);
      if (!stale) _queueProbe(c); // fresh builds already queued their probe
    }
    log('daily refresh done');
  }
}
