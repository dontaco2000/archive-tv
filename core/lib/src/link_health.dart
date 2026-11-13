import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'pool_builder.dart' show forEachLimited;
import 'stores.dart';

/// What one cheap request says about a file: there, gone, can't tell, or Archive asked us to slow down.
enum LinkCheck { ok, miss, inconclusive, throttled }

/// 404/403/410/451 = gone (removed, dark or restricted item); 429/503 = slow down; any other non-2xx = can't tell.
LinkCheck classifyStatus(int code) => switch (code) {
      >= 200 && < 300 => LinkCheck.ok,
      404 || 403 || 410 || 451 => LinkCheck.miss,
      429 || 503 => LinkCheck.throttled,
      _ => LinkCheck.inconclusive,
    };

/// HEAD on [url] (redirects followed to the storage server, as the player's resolve does); a 405/501 retries as a
/// 1-byte ranged GET. The body is never read: the response stream is cancelled at once. Timeouts and network
/// errors are [LinkCheck.inconclusive]. Archive answers a /download/ of an item that no longer exists with 503
/// (not 404), so a 503 there asks the item's metadata: `{}` (no such item) or `is_dark` = a miss, else a throttle.
Future<(LinkCheck, int?)> checkLink(http.Client client, String url, {Duration timeout = const Duration(seconds: 12)}) async {
  Future<int> send(String method) async {
    final req = http.Request(method, Uri.parse(url));
    if (method == 'GET') req.headers['Range'] = 'bytes=0-0';
    final res = await client.send(req).timeout(timeout);
    unawaited(res.stream.listen(null).cancel()); // a server that ignores Range must not stream the video to us
    return res.statusCode;
  }

  try {
    var code = await send('HEAD');
    if (code == 405 || code == 501) code = await send('GET');
    final item = RegExp(r'^/download/([^/]+)/').firstMatch(Uri.parse(url).path)?.group(1);
    if (code == 503 && item != null) {
      final meta = await client.get(Uri.parse(url).replace(path: '/metadata/$item', query: null)).timeout(timeout);
      final j = meta.statusCode == 200 ? jsonDecode(meta.body) : null;
      if (j is Map && (j.isEmpty || j['is_dark'] == true)) return (LinkCheck.miss, code);
    }
    return (classifyStatus(code), code);
  } on Object {
    return (LinkCheck.inconclusive, null);
  }
}

/// Pending strikes and dead-file rechecks (link_health.json), the dead list (dead.json, a [Blocklist] the scheduler
/// applies) and the human-readable report (dead_links.log), all in the data folder.
///
/// link_health.json is `{"strikes": {id: {...}}, "dead": {id: {...}}}`; a file from before rechecks (a plain map of
/// strikes) still loads. Dead ids without a `dead` record (an older dead.json) are rechecked at the next chance.
class LinkHealth {
  final File _strikesFile;
  final File logFile;

  /// Entry ids found dead (still rechecked, or gone for good): kept out of schedules and pools.
  final Blocklist dead;

  /// entry id -> first miss {first, code, channel, title, itemId}.
  final Map<String, Map<String, dynamic>> strikes;

  /// dead entry id -> {since, lastCheck, rechecks (failed ones), gone, url, title, itemId, channel}.
  final Map<String, Map<String, dynamic>> deadInfo;

  /// Entries seen fine this run (not saved): a later pass inside [okFor] skips them.
  final Map<String, DateTime> okAt = {};

  LinkHealth._(this._strikesFile, this.logFile, this.dead, this.strikes, this.deadInfo);

  factory LinkHealth.load(Directory dir) {
    File f(String n) => File('${dir.path}${Platform.pathSeparator}$n');
    final file = f('link_health.json');
    Map<String, Map<String, dynamic>> records(Object? m) => {
          if (m is Map)
            for (final MapEntry(:key, :value) in m.entries)
              if (value is Map) '$key': value.cast<String, dynamic>()
        };
    var strikes = <String, Map<String, dynamic>>{}, deadInfo = <String, Map<String, dynamic>>{};
    try {
      if (file.existsSync()) {
        final j = jsonDecode(file.readAsStringSync());
        if (j is Map && j['strikes'] is Map) {
          strikes = records(j['strikes']);
          deadInfo = records(j['dead']);
        } else {
          strikes = records(j); // the first format: strikes only
        }
      }
    } on Object {
      // corrupt: start over (strikes are only a hint; dead.json still blocks)
    }
    return LinkHealth._(file, f('dead_links.log'), Blocklist.load(dir, name: 'dead.json'), strikes, deadInfo);
  }

  void save() {
    _strikesFile.parent.createSync(recursive: true);
    final tmp = File('${_strikesFile.path}.tmp')
      ..writeAsStringSync(jsonEncode({'strikes': strikes, 'dead': deadInfo}), flush: true);
    tmp.renameSync(_strikesFile.path);
  }

  bool struck(String id) => strikes.containsKey(id);

  /// Failed its rechecks: blocked for good and never asked again.
  bool isGone(String id) => deadInfo[id]?['gone'] == true;

  /// Dead files still being rechecked (the menu count).
  int get activeDead => dead.ids.where((id) => !isGone(id)).length;

  /// Strikes whose first miss is at least [gap] old (and not past [maxAge]): due for their second check.
  bool hasDue(DateTime now, {Duration gap = const Duration(hours: 1), Duration maxAge = const Duration(hours: 24)}) =>
      strikes.values.any((s) {
        final age = now.difference(DateTime.parse(s['first'] as String));
        return age >= gap && age < maxAge;
      });

  /// Drops first strikes older than [maxAge]: one whose file left the checked window would never be rechecked,
  /// and a miss days later is not "two independent misses". Returns true if any went.
  bool expire(DateTime now, {Duration maxAge = const Duration(hours: 24)}) {
    final n = strikes.length;
    strikes.removeWhere((_, s) => now.difference(DateTime.parse(s['first'] as String)) >= maxAge);
    return strikes.length != n;
  }

  /// Dead files (not gone) last checked at least [every] ago (or never), as entries to check.
  List<Entry> dueRechecks(DateTime now, {Duration every = const Duration(days: 6)}) {
    bool due(String id) {
      final last = DateTime.tryParse(deadInfo[id]?['lastCheck'] as String? ?? '');
      return last == null || now.difference(last) >= every;
    }

    return [
      for (final id in dead.ids.toList()..sort())
        if (!isGone(id) && due(id))
          Entry(
              id: id,
              itemId: deadInfo[id]?['itemId'] as String? ?? id.split('/').first,
              file: id.substring(id.indexOf('/') + 1),
              title: deadInfo[id]?['title'] as String? ?? id,
              durationSeconds: 0,
              url: deadInfo[id]?['url'] as String? ?? Uri.https('archive.org', '/download/$id').toString()),
    ];
  }
}

/// Checks upcoming entries a channel at a time, throttled, and turns two misses at least [gap] apart into a dead
/// entry (one success in between clears the strike). A pass where more than [massMiss] of a channel's checked
/// entries miss (and at least 2) is taken as Archive or network trouble and thrown away. Dead files are rechecked
/// about weekly ([recheckDead]): an answer revives them, [goneAfter] failed rechecks block them for good.
class DeadLinkChecker {
  final http.Client client;
  final LinkHealth health;
  final int concurrency;

  /// Pause after each request, per worker.
  final Duration delay;
  final Duration gap;
  final double massMiss;

  /// An entry seen fine this recently is not asked again.
  final Duration okFor;

  /// Spacing of a dead file's rechecks, and how many failed rechecks make it gone for good.
  final Duration recheckEvery;
  final int goneAfter;

  /// True while checking must wait (Android in the background, a tune starting).
  final bool Function() paused;
  final Future<void> Function(Duration) sleep;
  final void Function(String) log;

  Duration _backoff;
  int _throttles = 0, _oks = 0, _discarded = 0;

  DeadLinkChecker(
    this.client,
    this.health, {
    this.concurrency = 2,
    this.delay = const Duration(milliseconds: 500),
    this.gap = const Duration(hours: 1),
    this.massMiss = 0.3,
    this.okFor = const Duration(hours: 12),
    this.recheckEvery = const Duration(days: 6),
    this.goneAfter = 3,
    Duration backoff = const Duration(seconds: 30),
    bool Function()? paused,
    Future<void> Function(Duration)? sleep,
    void Function(String)? log,
  })  : _backoff = backoff,
        paused = paused ?? (() => false),
        sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        log = log ?? ((_) {});

  /// Four 429/503s in a run: Archive wants us gone; the rest of the run is skipped.
  bool get gaveUp => _throttles >= 4;

  Future<Map<Entry, (LinkCheck, int?)>> _checkAll(List<Entry> todo) async {
    final results = <Entry, (LinkCheck, int?)>{};
    await forEachLimited(todo, concurrency, (e) async {
      while (paused()) {
        await sleep(const Duration(seconds: 1));
      }
      if (gaveUp) return;
      final r = await checkLink(client, e.url);
      if (r.$1 == LinkCheck.throttled) {
        _throttles++;
        log('link check: Archive said ${r.$2}, backing off ${_backoff.inSeconds} s');
        await sleep(_backoff);
        if (_backoff < const Duration(minutes: 10)) _backoff *= 2;
      }
      results[e] = r;
      await sleep(delay);
    });
    return results;
  }

  /// Checks [entries] of channel [name] (number [channel]); returns the ones that just became dead (already added
  /// to [LinkHealth.dead] and the log). [now] is read per check (passes can take a while).
  Future<List<Entry>> checkChannel(int channel, String name, List<Entry> entries, {DateTime Function()? now}) async {
    final clock = now ?? DateTime.now;
    health.expire(clock());
    final todo = [
      for (final e in entries)
        if (!health.dead.ids.contains(e.id) && !(clock().difference(health.okAt[e.id] ?? DateTime(0)) < okFor)) e
    ];
    final results = await _checkAll(todo);
    final misses = [for (final MapEntry(:key, :value) in results.entries) if (value.$1 == LinkCheck.miss) key];
    final oks = [for (final MapEntry(:key, :value) in results.entries) if (value.$1 == LinkCheck.ok) key];
    final t = clock();
    _oks += oks.length;
    for (final e in oks) {
      health.okAt[e.id] = t;
      health.strikes.remove(e.id);
    }
    if (misses.length >= 2 && misses.length > massMiss * results.length) {
      _discarded++;
      log('link check $name: ${misses.length} of ${results.length} missed, assuming Archive/network trouble: pass discarded');
      health.save();
      return const [];
    }
    final dead = <Entry>[];
    for (final e in misses) {
      final code = results[e]!.$2;
      final s = health.strikes[e.id];
      if (s == null) {
        health.strikes[e.id] = {'first': t.toIso8601String(), 'code': code, 'channel': channel, 'title': e.title, 'itemId': e.itemId};
        continue;
      }
      final first = DateTime.parse(s['first'] as String);
      if (t.difference(first) < gap) continue; // same pass window: not a second, independent miss
      health.strikes.remove(e.id);
      health.dead.add(e.id);
      health.deadInfo[e.id] = {
        'since': t.toIso8601String(),
        'lastCheck': t.toIso8601String(),
        'rechecks': 0,
        'url': e.url,
        'title': e.title,
        'itemId': e.itemId,
        'channel': channel,
      };
      dead.add(e);
      _write('${_ts(t)}  ch $channel $name  "${e.title}"  item ${e.itemId}  file ${e.file}  '
          'first miss ${_ts(first)}, second ${_ts(t)} (HTTP ${code ?? '?'})  ${e.url}');
      log('link check $name: ${e.id} is dead (HTTP $code twice)');
    }
    health.save();
    log('link check $name: ${results.length} checked, ${oks.length} ok, ${misses.length} missed, ${dead.length} dead');
    return dead;
  }

  /// Rechecks dead files last checked at least [recheckEvery] ago. One that answers is revived (off dead.json,
  /// strikes cleared); one that misses gets a recheck strike, and after [goneAfter] of them it is gone for good
  /// (stays blocked, never rechecked). Inconclusive answers count for nothing and leave it due.
  /// Dead files are expected to miss, so they can't judge Archive's health themselves: this only runs after this
  /// checker's channel checks looked healthy (something answered OK now or within the hour, no channel pass
  /// discarded, no give-up). Returns the revived and the newly gone ids.
  Future<({List<String> revived, List<String> gone})> recheckDead({DateTime Function()? now}) async {
    final clock = now ?? DateTime.now;
    final due = health.dueRechecks(clock(), every: recheckEvery);
    final revived = <String>[], gone = <String>[];
    if (due.isEmpty) return (revived: revived, gone: gone);
    final recentOk = health.okAt.values.any((t) => clock().difference(t) < const Duration(hours: 1));
    if (gaveUp || _discarded > 0 || (_oks == 0 && !recentOk)) {
      log('link check: ${due.length} dead rechecks put off (Archive/network looks unhealthy this pass)');
      return (revived: revived, gone: gone);
    }
    final results = await _checkAll(due);
    final t = clock();
    for (final MapEntry(key: e, value: (r, code)) in results.entries) {
      if (r == LinkCheck.ok) {
        health.dead.remove(e.id);
        health.deadInfo.remove(e.id);
        health.strikes.remove(e.id);
        health.okAt[e.id] = t;
        revived.add(e.id);
        _write('${_ts(t)}  revived  "${e.title}"  item ${e.itemId}  file ${e.file}  (answers again)  ${e.url}');
      } else if (r == LinkCheck.miss) {
        final info = health.deadInfo[e.id] ??= {'url': e.url, 'title': e.title, 'itemId': e.itemId};
        final n = (info['rechecks'] as int? ?? 0) + 1;
        info['rechecks'] = n;
        info['lastCheck'] = t.toIso8601String();
        if (n >= goneAfter) {
          info['gone'] = true;
          gone.add(e.id);
          _write('${_ts(t)}  removed for good  "${e.title}"  item ${e.itemId}  file ${e.file}  '
              '($n failed rechecks, last HTTP ${code ?? '?'})  ${e.url}');
        }
      }
    }
    health.save();
    log('link check: ${results.length} dead rechecked, ${revived.length} revived, ${gone.length} removed for good');
    return (revived: revived, gone: gone);
  }

  static String _ts(DateTime d) => d.toIso8601String().substring(0, 16).replaceFirst('T', ' ');

  void _write(String line) {
    try {
      health.logFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } on Object catch (x) {
      log('dead_links.log write failed: $x');
    }
  }
}
