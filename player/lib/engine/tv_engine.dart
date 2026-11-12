import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/foundation.dart';
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

/// Where a channel's pool stands (see [TvEngine.statusOf]).
enum PoolStatus { building, ready, failed }

/// Shown when a building channel is tuned (player) and in the guide's detail line.
const buildingMessage = 'This channel is in its build mode,\nplease choose another channel for now.';

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

  /// Items the viewer marked "wrong channel" (key X / menu), kept off that channel only; wrong_items.json.
  final ChannelBlocklist wrong;

  /// Audit trail of "wrong channel" presses, one JSON object per line (wrong_channel.jsonl).
  final File wrongLog;

  /// Probes upcoming files after each fresh pool build; null turns probing off (tests).
  final http.Client? probeClient;
  final void Function(String) log;

  /// Archive metadata fetches in flight during a pool build (lower on 1 GB Android TV sticks).
  final int buildConcurrency;

  final Map<int, List<Entry>> _pool = {};

  TvEngine._(this.config, this.api, this.pools, this.snapshots, this.blocklist, this.slow, this.noSubs, this.wrong, this.wrongLog,
      this.probeClient, this.log, this.buildConcurrency);

  /// [configText] is the contents of channels.json, [ratedText] of rated.json (null: no R list, default
  /// window); [dataDir] holds pools, snapshots, blocklist.
  factory TvEngine.open({
    required String configText,
    String? ratedText,
    required Directory dataDir,
    ArchiveApi? api,
    http.Client? probeClient,
    void Function(String)? log,
    int buildConcurrency = 4,
  }) {
    return TvEngine._(
      parseChannelConfig(configText, ratedText: ratedText),
      api ?? ArchiveClient(),
      PoolStore(Directory(p.join(dataDir.path, 'pools'))),
      SnapshotStore(Directory(p.join(dataDir.path, 'days'))),
      Blocklist.load(dataDir),
      Blocklist.load(dataDir, name: 'slow.json'),
      Blocklist.load(dataDir, name: 'nosubs.json'),
      ChannelBlocklist.load(dataDir),
      File(p.join(dataDir.path, 'wrong_channel.jsonl')),
      probeClient,
      log ?? (_) {},
      buildConcurrency,
    );
  }

  List<Channel> get channels => config.channels;

  /// The channel's loaded pool (blocked and no-subtitle items removed); empty if not loaded.
  List<Entry> poolOf(Channel c) => noSubs.apply(_pool[c.number] ?? const []);

  final Map<int, bool Function(Entry)> _rated = {};

  /// Whether an entry of [c] is known to be R-rated (rated.json, source flag, Archive rating); cached per channel.
  bool Function(Entry) ratedOf(Channel c) => _rated[c.number] ??= ratedTest(c, config);

  /// [poolOf] for On Demand: outside the channel's rated window (daytime) R-rated entries are hidden, as they
  /// are off the air then.
  List<Entry> onDemandPoolOf(Channel c, {DateTime? now}) {
    final pool = poolOf(c);
    if (ratedWindowOf(c, config).contains(now ?? DateTime.now())) return pool;
    final r = ratedOf(c);
    return [for (final e in pool) if (!r(e)) e];
  }

  /// Logs how much of [c]'s pool is R-rated, and when its unrated part is under the minimum (the daytime then
  /// repeats it; with nothing unrated at all, rated entries air in the daytime rather than dead air).
  void _logRated(Channel c) {
    final pool = _pool[c.number];
    final w = ratedWindowOf(c, config);
    if (pool == null || w.unrestricted) return;
    final r = ratedOf(c);
    final rated = pool.where(r).toList();
    if (rated.isEmpty) return;
    double hours(Iterable<Entry> l) => l.fold(0.0, (s, e) => s + e.durationSeconds) / 3600;
    final rest = pool.where((e) => !r(e)).toList();
    log('${c.name}: ${rated.length} R-rated entries (${hours(rated).toStringAsFixed(1)} h) air only in the rated window');
    if (isOffAir(rest, config.minContentSeconds)) {
      log('${c.name}: only ${hours(rest).toStringAsFixed(1)} h not rated: the daytime repeats it'
          '${rest.isEmpty ? ' (none at all: rated entries air in the daytime too)' : ''}');
    }
  }

  /// [e] as the current pool has it: a day saved from an older pool lacks newer fields (language, subtitles).
  Entry fresh(Channel c, Entry e) => _pool[c.number]?.where((p) => p.id == e.id).firstOrNull ?? e;

  /// Channels that can be tuned now: archive channels whose pool has enough content,
  /// plus weather channels (always on; their music is optional).
  /// Call [ensurePool] first for channels you want considered.
  List<Channel> get tunable => [for (final c in config.channels) if (statusOf(c) == PoolStatus.ready) c];

  /// [PoolStatus.ready]: weather, or a loaded pool with enough content (a rebuild may run behind it).
  /// [PoolStatus.building]: no usable pool yet and a build is running or not tried yet this run.
  /// [PoolStatus.failed]: tried and still nothing playable (build failed, too little content, no sources).
  PoolStatus statusOf(Channel c) {
    if (c.type == 'weatherstar' || (_pool.containsKey(c.number) && !isOffAir(poolOf(c), config.minContentSeconds))) {
      return PoolStatus.ready;
    }
    if (c.sources.isNotEmpty && (_building.containsKey(c.number) || !_tried.contains(c.number))) return PoolStatus.building;
    return PoolStatus.failed;
  }

  final Map<int, Future<void>> _building = {};
  final Set<int> _tried = {}; // channels whose pool load/build has finished at least once this run

  /// Bumped each time a pool load/build finishes, so open screens (the guide) can refresh.
  final ValueNotifier<int> poolsChanged = ValueNotifier(0);

  /// Loads the channel's saved pool (cut to the current config, see `refilterPool`), however old or whatever
  /// config made it, and builds it from Archive only when there is none or too little of it is left.
  /// A stale saved pool stays on air while [dailyRefresh] rebuilds it, then the new one swaps in.
  /// Concurrent callers for the same channel share one build.
  /// [maxAge] zero forces a rebuild even when the pool is already loaded (menu "Refresh channels").
  Future<void> ensurePool(Channel channel, {Duration maxAge = const Duration(days: 1)}) {
    if (channel.sources.isEmpty || (maxAge > Duration.zero && _pool.containsKey(channel.number))) return Future.value();
    return _building[channel.number] ??= _ensurePool(channel, maxAge).whenComplete(() {
      _building.remove(channel.number);
      _logRated(channel);
      _tried.add(channel.number);
      poolsChanged.value++;
    });
  }

  Future<void> _ensurePool(Channel channel, Duration maxAge) async {
    final raw = pools.load(channel.number);
    // An app update may have changed the channel's sources or the global excludes: serve what still fits.
    final saved = raw == null ? null : refilterPool(channel, config, raw);
    final usable = saved != null && !isOffAir(saved, config.minContentSeconds);
    final load = usable && maxAge > Duration.zero; // zero = forced rebuild (daily refresh of a stale pool, Refresh)
    await _ensureSerials(channel, rebuild: !load);
    if (load) {
      _pool[channel.number] = _blocked(channel).apply(saved);
      return;
    }
    try {
      final built = await buildPool(channel, config, api, concurrency: buildConcurrency, log: log);
      if (built.isEmpty) {
        // buildPool logs failed searches and returns what it has; an empty result means
        // the refresh failed. Never save it; keep the pool we already had, if any.
        log('${channel.name}: build found nothing${saved != null ? ', keeping the saved pool' : ''}');
        if (saved != null) _pool[channel.number] = _blocked(channel).apply(saved);
        return;
      }
      pools.save(channel.number, built);
      _pool[channel.number] = _blocked(channel).apply(built); // the old pool served until this line
      if (raw != null) snapshots.dropAfter(channel.number, DateTime.now()); // later days from the new pool
      _queueProbe(channel);
    } on Object catch (e) {
      log('pool build failed for ${channel.name}: $e'); // fall back to a stale pool if there is one
      if (saved != null) _pool[channel.number] = _blocked(channel).apply(saved);
    }
  }

  /// Serial episode lists per channel, `[slot][show]` (see `buildSerialEpisodes`).
  final Map<int, List<List<List<Entry>>>> _serials = {};

  /// Loads the channel's saved serial episode lists, building them when [rebuild], missing or made
  /// for an older serial config. A failed build keeps the saved lists.
  Future<void> _ensureSerials(Channel c, {required bool rebuild}) async {
    if (c.serials.isEmpty) return;
    final saved = pools.loadSerials(c);
    if (saved != null && !rebuild) {
      _serials[c.number] = saved;
      return;
    }
    try {
      final built = await buildSerialEpisodes(c, api, log: log);
      if (built.any((slot) => slot.any((show) => show.isNotEmpty))) {
        pools.saveSerials(c, built);
        _serials[c.number] = built;
        return;
      }
      log('${c.name}: no serial episodes found${saved != null ? ', keeping the saved ones' : ''}');
    } on Object catch (e) {
      log('serial build failed for ${c.name}: $e');
    }
    if (saved != null) _serials[c.number] = saved;
  }

  /// The pool the day's shuffle is made from: serial episodes and rare-source entries never air in it.
  List<Entry> _shufflePool(Channel c) {
    final pool = _pool[c.number] ?? const <Entry>[];
    final eps = _serials[c.number];
    final ids = {if (eps != null) for (final slot in eps) for (final show in slot) for (final e in show) e.id};
    return [for (final e in pool) if (!ids.contains(e.id) && !isRare(c, e)) e];
  }

  /// Serial, rare-source (`perDay`) and themed time blocks for a day; null when the channel has none.
  List<SerialBlock> Function(DateTime)? _blocksFor(Channel c) =>
      c.serials.isEmpty && c.timeBlocks.isEmpty && !c.sources.any((s) => s.perDay != null)
          ? null
          : (d) => dayBlocks(c, _serials[c.number] ?? const [], _pool[c.number] ?? const [], d);

  /// The viewer's blocks plus the channel's wrong-channel items.
  Blocklist _blocked(Channel c) => blocklist.union(wrong.forChannel(c.number));

  /// "Wrong channel for this program": logs [e] to [wrongLog] and keeps its item off [c] for good
  /// (other channels still air it). The next [airing]/[guideFor] re-lays the day without it.
  void markWrongChannel(Channel c, Entry e, {DateTime? now}) {
    final record = {
      'time': (now ?? DateTime.now()).toIso8601String(),
      'channel': c.number,
      'channelName': c.name,
      'itemId': e.itemId,
      'entryId': e.id,
      'title': e.title,
    };
    for (final save in [
      () => wrongLog.writeAsStringSync('${jsonEncode(record)}\n', mode: FileMode.append, flush: true),
      () => wrong.add(c.number, e.itemId), // blocked in memory even if the save fails
    ]) {
      try {
        save();
      } on Object catch (x) {
        log('wrong-channel save failed: $x');
      }
    }
    final pool = _pool[c.number];
    if (pool != null) _pool[c.number] = wrong.forChannel(c.number).apply(pool);
    log('${c.name}: ${e.itemId} marked wrong channel');
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

  List<Slot> _day(Channel c, DateTime day) {
    // by id from the current pool: a day saved from an older pool has entries without the source tag
    final rare = {for (final e in _pool[c.number] ?? const <Entry>[]) if (isRare(c, e)) e.id};
    final fits = poolFilter(c, config); // a day saved under an older config may hold now-excluded items
    return snapshots.day(c.number, day, _shufflePool(c),
        blocklist: _blocked(c).union(_skipped).union(slow).union(noSubs),
        serials: _blocksFor(c),
        inShuffle: (e) => fits(e) && !rare.contains(e.id),
        rated: ratedOf(c),
        window: ratedWindowOf(c, config));
  }

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
    snapshots.ensureWeek(channel.number, now, _shufflePool(channel), serials: _blocksFor(channel));
    snapshots.prune(now);
  }

  /// The once-a-day job (launch and each local midnight): rebuilds pools older than [maxAge],
  /// saves the new week's days, deletes past ones and probes the next 12 hours of every channel.
  /// Stale pools stay on air during their rebuild. [busy] (Android: a video is starting) holds each rebuild back up to 20 s.
  Future<void> dailyRefresh(DateTime now, {Duration maxAge = const Duration(days: 1), bool Function()? busy}) async {
    for (final c in channels) {
      if (c.sources.isEmpty) continue;
      final age = pools.age(c.number);
      final stale = age == null || age >= maxAge;
      for (var i = 0; stale && busy != null && i < 40 && busy(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
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
