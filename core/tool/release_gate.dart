// Release gate: run before each installer/APK build, from app\core:
//   dart run tool/release_gate.dart [--offline] [--channels=61] [--report=<file.md>]
// Checks channels.json (count, numbers, genre/name/logo, query length, duplicate excludes), that every
// source still finds something on the live Archive (3 searches at a time), and the Android seed pools
// (exactly the configured channels, each >= minContentHours; item share > 8% and adult/junk titles are
// warnings). Writes a markdown report; exit code 1 if anything FAILs.
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';

const _assets = '../player/assets';
const _maxQuery = 2048; // Archive answers 400 above this many characters of q (see setlist-sideline report)

/// Adult / junk title words, matched as whole words, case-insensitive (report only).
final _suspect = RegExp(
    r'\b(xxx|porn\w*|nsfw|erotic\w*|nude|nudes|naked|topless|stripper|strip ?tease|playboy|hentai|fetish|softcore|'
    r'sexy|thumbnail|placeholder|s00e00|test upload|untitled)\b',
    caseSensitive: false);

Future<void> main(List<String> args) async {
  String? opt(String name) => args.where((a) => a.startsWith('--$name=')).map((a) => a.substring(name.length + 3)).firstOrNull;
  final expected = int.parse(opt('channels') ?? '61');
  final reportFile = File(opt('report') ?? '../../_build/release_gate-report.md');
  final fails = <String>[], warns = <String>[], notes = <String>[];

  // ---- channels.json
  final text = File('$_assets/channels.json').readAsStringSync();
  final raw = jsonDecode(text) as Map<String, dynamic>;
  // ---- rated.json: parses, ids look like Archive identifiers (optionally item/file)
  final ratedText = File('$_assets/rated.json').readAsStringSync();
  final config = parseChannelConfig(text, ratedText: ratedText);
  final idShape = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*(/.+)?$');
  for (final id in config.rated.identifiers) {
    if (!idShape.hasMatch(id)) fails.add('rated.json: "$id" is not a plausible Archive identifier');
  }
  notes.add('rated.json: ${config.rated.identifiers.length} ids, ${config.rated.titlePatterns.length} title patterns, '
      'window ${config.rated.window.startMinute ~/ 60}:00-${config.rated.window.endMinute ~/ 60}:00; '
      'rated sources: ${[for (final c in config.channels) for (final (i, s) in c.sources.indexed) if (s.rated != null) '${c.name} $i'].join(', ')}');
  final chans = config.channels;
  if (chans.length != expected) fails.add('channels.json has ${chans.length} channels, expected $expected');
  final numbers = <int>{}, names = <String>{};
  for (final c in chans) {
    if (!numbers.add(c.number)) fails.add('channel number ${c.number} used twice');
    if (!names.add(c.name.toLowerCase())) fails.add('channel name ${c.name} used twice');
    if (c.name.trim().isEmpty) fails.add('channel ${c.number} has no name');
    if (c.genre.trim().isEmpty) fails.add('${c.number} ${c.name}: no genre');
    final logo = File('$_assets/logos/${c.name.toLowerCase().replaceAll(RegExp(r'[\s-]'), '')}.png');
    if (!logo.existsSync()) fails.add('${c.number} ${c.name}: logo asset missing (${logo.path})');
    for (final (i, s) in c.sources.indexed) {
      final q = buildQuery(s, range: c.yearRange ?? config.yearRange, blockCollections: config.blockCollections);
      if (q.length > _maxQuery) fails.add('${c.number} ${c.name} source $i: query is ${q.length} chars (> $_maxQuery)');
    }
  }
  final excl = (raw['excludeIdentifiers'] as List? ?? const []).cast<String>();
  final seen = <String>{};
  final dupes = {for (final x in excl) if (!seen.add(x)) x};
  if (dupes.isNotEmpty) fails.add('excludeIdentifiers has duplicates: ${dupes.join(', ')}');
  final sourceCount = chans.fold(0, (n, c) => n + c.sources.length);
  notes.add('${chans.length} channels, $sourceCount sources, ${excl.length} excluded identifiers');

  // ---- live Archive: every source must still find something
  if (!args.contains('--offline')) {
    final api = ArchiveClient(maxAttempts: 4, retryDelay: const Duration(seconds: 3));
    final jobs = [for (final c in chans) for (final (i, s) in c.sources.indexed) (c, i, s)];
    var empty = 0;
    final sw = Stopwatch()..start();
    await forEachLimited(jobs, 3, (job) async {
      final (c, i, s) = job;
      final q = buildQuery(s, range: c.yearRange ?? config.yearRange, blockCollections: config.blockCollections);
      final label = '${c.number} ${c.name} source $i';
      try {
        final hits = await api.search(q, rows: 1);
        if (hits.isEmpty) {
          empty++;
          fails.add('$label: no results on Archive');
        }
      } on Object catch (e) {
        fails.add('$label: search failed: $e');
      }
    });
    notes.add('live search: ${jobs.length} sources checked in ${sw.elapsed.inSeconds} s, $empty empty');
  } else {
    notes.add('live search skipped (--offline)');
  }

  // ---- seed pools (Android)
  final seedFile = File('$_assets/seed_pools.jsonl.gz');
  final seeded = <int, List<Entry>>{};
  String? seedAt;
  for (final line in const LineSplitter().convert(utf8.decode(gzip.decode(seedFile.readAsBytesSync())))) {
    if (line.trim().isEmpty) continue;
    final j = jsonDecode(line) as Map<String, dynamic>;
    if (j.containsKey('seed')) {
      seedAt = j['builtAt'] as String?;
      continue;
    }
    seeded[j['n'] as int] = [for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) expandEntry(e)];
  }
  notes.add('seed pools built $seedAt, ${seeded.length} channels');
  final want = {for (final c in chans) if (c.sources.isNotEmpty) c.number};
  final missing = want.difference(seeded.keys.toSet()), extra = seeded.keys.toSet().difference(want);
  if (missing.isNotEmpty) fails.add('seed pools missing channels: ${(missing.toList()..sort()).join(', ')}');
  if (extra.isNotEmpty) fails.add('seed pools have unconfigured channels: ${(extra.toList()..sort()).join(', ')}');
  final suspects = <String>[];
  for (final c in chans) {
    final pool = seeded[c.number];
    if (pool == null) continue;
    final served = refilterPool(c, config, pool); // what the app keeps under the current config
    final total = served.fold(0.0, (s, e) => s + e.durationSeconds);
    if (total < config.minContentSeconds) {
      fails.add('${c.number} ${c.name}: seed pool ${(total / 3600).toStringAsFixed(1)} h after filters (< ${config.minContentSeconds ~/ 3600} h)');
    }
    final isRated = ratedTest(c, config);
    final rated = served.where(isRated).fold(0.0, (s, e) => s + e.durationSeconds);
    if (rated > 0) {
      notes.add('${c.number} ${c.name}: ${(rated / 3600).toStringAsFixed(1)} h R-rated in the seed pool (night only)');
      if (total - rated < config.minContentSeconds) {
        warns.add('${c.number} ${c.name}: only ${((total - rated) / 3600).toStringAsFixed(1)} h not rated: the daytime repeats it');
      }
    }
    final byItem = <String, double>{};
    final shuffled = served.where((e) => !isRare(c, e)); // perDay entries air N a day, not by pool share
    final shuffledTotal = shuffled.fold(0.0, (s, e) => s + e.durationSeconds);
    for (final e in shuffled) {
      byItem[e.itemId] = (byItem[e.itemId] ?? 0) + e.durationSeconds;
    }
    for (final MapEntry(:key, :value) in byItem.entries) {
      if (c.type == 'archive' && shuffledTotal > 0 && value / shuffledTotal > 0.08) { // weather music is one item by design
        warns.add('${c.number} ${c.name}: item $key is ${(100 * value / shuffledTotal).toStringAsFixed(1)}% of the pool');
      }
    }
    for (final e in served) {
      final m = _suspect.firstMatch(e.title);
      if (m != null) suspects.add('${c.number} ${c.name}: "${e.title}" (${e.itemId}) [${m[0]}]');
    }
  }

  // ---- report
  final ok = fails.isEmpty;
  final out = StringBuffer()
    ..writeln('# Release gate: ${ok ? 'PASS' : 'FAIL'}')
    ..writeln()
    ..writeln('Run ${DateTime.now().toIso8601String().substring(0, 16)}. ${fails.length} fail, ${warns.length} warn, '
        '${suspects.length} suspect titles.')
    ..writeln()
    ..writeln('## Summary')
    ..writeAll([for (final n in notes) '- $n\n'])
    ..writeln()
    ..writeln('## FAIL (${fails.length})')
    ..writeAll([for (final f in fails..sort()) '- $f\n'])
    ..writeln()
    ..writeln('## WARN: item over 8% of a channel (${warns.length})')
    ..writeAll([for (final w in warns..sort()) '- $w\n'])
    ..writeln()
    ..writeln('## Suspect titles in seed pools, report only (${suspects.length})')
    ..writeAll([for (final s in suspects) '- $s\n']);
  reportFile.writeAsStringSync(out.toString());
  stdout.writeln('release gate: ${ok ? 'PASS' : 'FAIL'} (${fails.length} fail, ${warns.length} warn, ${suspects.length} suspect) -> ${reportFile.path}');
  exitCode = ok ? 0 : 1;
}
