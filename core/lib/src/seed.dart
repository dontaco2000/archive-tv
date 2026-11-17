import 'dart:convert';
import 'dart:io';

import 'file_picker.dart';
import 'models.dart';
import 'scheduler.dart';
import 'stores.dart';

/// Seeded pools: pools built on the PC, trimmed and shipped in the Android APK so a 1 GB stick has a
/// full guide on first launch without thousands of metadata lookups.
///
/// File format (gzip, one JSON object per line): a header `{"seed":1,"builtAt":...}`, then one line per
/// channel `{"n":<channel>,"builtAt":...,"entries":[<compact entry>...],"serials":<serials file or null>}`.

/// [pool] cut to at most [maxSeconds]: rare (`perDay`) and `blockOnly` entries all stay; the rest is thinned evenly over
/// the id-sorted pool, so every source and item keeps its share. Pools under the limit are returned as is.
List<Entry> trimPool(Channel c, List<Entry> pool, double maxSeconds) {
  double total(Iterable<Entry> l) => l.fold(0.0, (s, e) => s + e.durationSeconds);
  bool always(Entry e) => isRare(c, e) || isBlockOnly(c, e); // their blocks need them all
  final rest = [for (final e in pool) if (!always(e)) e]..sort((a, b) => a.id.compareTo(b.id));
  final budget = maxSeconds - total(pool.where(always));
  final restTotal = total(rest);
  if (restTotal <= budget) return pool;
  final n = budget <= 0 ? 0 : (rest.length * budget / restTotal).floor();
  final keep = {for (var i = 0; i < n; i++) rest[i * rest.length ~/ n]};
  return [for (final e in pool) if (always(e) || keep.contains(e)) e];
}

/// [e]'s JSON without what can be rebuilt: `id` and `url` when they follow the usual pattern.
Map<String, dynamic> compactEntry(Entry e) => e.toJson()
  ..remove('id')
  ..remove('url')
  ..addAll({
    if (e.id != '${e.itemId}/${e.file}') 'id': e.id,
    if (e.url != downloadUrl(e.itemId, e.file)) 'url': e.url,
  });

/// The inverse of [compactEntry].
Entry expandEntry(Map<String, dynamic> j) => Entry.fromJson({
      'id': '${j['itemId']}/${j['file']}',
      'url': downloadUrl(j['itemId'] as String, j['file'] as String),
      ...j,
    });

/// Writes the seed's pools (and serial lists) into [poolDir] for channels whose pool is missing or older
/// than the seed, one channel at a time from the gzip stream. Skips everything when [poolDir]'s
/// `seed.stamp` already names this seed. With [onlyMissing] a channel that already has its own pool is never
/// touched (Windows: the seed is a trimmed copy, so it only fills channels that have nothing yet).
/// Returns how many channels were written.
Future<int> installSeed(Stream<List<int>> gz, Directory poolDir, {bool onlyMissing = false}) async {
  final stamp = File('${poolDir.path}${Platform.pathSeparator}seed.stamp');
  final pools = PoolStore(poolDir);
  String? seedAt;
  var written = 0;
  await for (final line in gz.transform(gzip.decoder).transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final j = jsonDecode(line) as Map<String, dynamic>;
    if (seedAt == null) {
      seedAt = j['builtAt'] as String;
      if (stamp.existsSync() && stamp.readAsStringSync() == seedAt) return 0; // cancels the stream
      continue;
    }
    final n = j['n'] as int;
    final builtAt = DateTime.parse(j['builtAt'] as String);
    final age = pools.age(n);
    if (onlyMissing && age != null) continue;
    if (age != null && !DateTime.now().subtract(age).isBefore(builtAt)) continue; // own pool is newer
    pools.save(n, [for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) expandEntry(e)], builtAt: builtAt);
    final serials = j['serials'];
    if (serials != null) {
      final f = File('${poolDir.path}${Platform.pathSeparator}serials-$n.json');
      File('${f.path}.tmp')
        ..writeAsStringSync(jsonEncode(serials), flush: true)
        ..renameSync(f.path);
    }
    written++;
  }
  if (seedAt != null) {
    poolDir.createSync(recursive: true);
    stamp.writeAsStringSync(seedAt);
  }
  return written;
}
