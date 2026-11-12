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

/// Pending strikes (link_health.json), the dead list (dead.json, a [Blocklist] the scheduler applies) and the
/// human-readable report (dead_links.log), all in the data folder.
class LinkHealth {
  final File _strikesFile;
  final File logFile;

  /// Entry ids found dead: kept out of schedules and pools for good.
  final Blocklist dead;

  /// entry id -> first miss {first, code, channel, title, itemId}.
  final Map<String, Map<String, dynamic>> strikes;

  /// Entries seen fine this run (not saved): a later pass inside [okFor] skips them.
  final Map<String, DateTime> okAt = {};

  LinkHealth._(this._strikesFile, this.logFile, this.dead, this.strikes);

  factory LinkHealth.load(Directory dir) {
    File f(String n) => File('${dir.path}${Platform.pathSeparator}$n');
    final file = f('link_health.json');
    var strikes = <String, Map<String, dynamic>>{};
    try {
      if (file.existsSync()) {
        strikes = {
          for (final MapEntry(:key, :value) in (jsonDecode(file.readAsStringSync()) as Map).entries)
            if (value is Map) '$key': value.cast<String, dynamic>(),
        };
      }
    } on Object {
      // corrupt: start over (strikes are only a hint)
    }
    return LinkHealth._(file, f('dead_links.log'), Blocklist.load(dir, name: 'dead.json'), strikes);
  }

  void save() {
    _strikesFile.parent.createSync(recursive: true);
    final tmp = File('${_strikesFile.path}.tmp')..writeAsStringSync(jsonEncode(strikes), flush: true);
    tmp.renameSync(_strikesFile.path);
  }

  bool struck(String id) => strikes.containsKey(id);

  /// Strikes whose first miss is at least [gap] old: due for their second check.
  bool hasDue(DateTime now, {Duration gap = const Duration(hours: 1)}) =>
      strikes.values.any((s) => now.difference(DateTime.parse(s['first'] as String)) >= gap);
}

/// Checks upcoming entries a channel at a time, throttled, and turns two misses at least [gap] apart into a dead
/// entry (one success in between clears the strike). A pass where more than [massMiss] of a channel's checked
/// entries miss (and at least 2) is taken as Archive or network trouble and thrown away.
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

  /// True while checking must wait (Android in the background, a tune starting).
  final bool Function() paused;
  final Future<void> Function(Duration) sleep;
  final void Function(String) log;

  Duration _backoff;
  int _throttles = 0;

  DeadLinkChecker(
    this.client,
    this.health, {
    this.concurrency = 2,
    this.delay = const Duration(milliseconds: 500),
    this.gap = const Duration(hours: 1),
    this.massMiss = 0.3,
    this.okFor = const Duration(hours: 12),
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

  /// Checks [entries] of channel [name] (number [channel]); returns the ones that just became dead (already added
  /// to [LinkHealth.dead] and the log). [now] is read per check (passes can take a while).
  Future<List<Entry>> checkChannel(int channel, String name, List<Entry> entries, {DateTime Function()? now}) async {
    final clock = now ?? DateTime.now;
    final todo = [
      for (final e in entries)
        if (!health.dead.ids.contains(e.id) && !(clock().difference(health.okAt[e.id] ?? DateTime(0)) < okFor)) e
    ];
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
    final misses = [for (final MapEntry(:key, :value) in results.entries) if (value.$1 == LinkCheck.miss) key];
    final oks = [for (final MapEntry(:key, :value) in results.entries) if (value.$1 == LinkCheck.ok) key];
    final t = clock();
    for (final e in oks) {
      health.okAt[e.id] = t;
      health.strikes.remove(e.id);
    }
    if (misses.length >= 2 && misses.length > massMiss * results.length) {
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
      dead.add(e);
      _report(channel, name, e, first, t, code);
    }
    health.save();
    log('link check $name: ${results.length} checked, ${oks.length} ok, ${misses.length} missed, ${dead.length} dead');
    return dead;
  }

  void _report(int channel, String name, Entry e, DateTime first, DateTime second, int? code) {
    String ts(DateTime d) => d.toIso8601String().substring(0, 16).replaceFirst('T', ' ');
    final line = '${ts(second)}  ch $channel $name  "${e.title}"  item ${e.itemId}  file ${e.file}  '
        'first miss ${ts(first)}, second ${ts(second)} (HTTP ${code ?? '?'})  ${e.url}\n';
    try {
      health.logFile.writeAsStringSync(line, mode: FileMode.append, flush: true);
    } on Object catch (x) {
      log('dead_links.log write failed: $x');
    }
    log('link check $name: ${e.id} is dead (HTTP $code twice)');
  }
}
