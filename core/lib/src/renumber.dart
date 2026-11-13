import 'dart:convert';
import 'dart:io';

/// One-time move of an installed data folder to a new channel numbering (the 2026-11-13 regroup by theme).
///
/// Pools, serial lists and saved days are files named by channel number, and settings keep favorites,
/// the last channel and parental locks by number. After a renumber, old `pool-43.json` would load under
/// new channel 43, i.e. another channel's content; this moves everything to the new numbers instead.
///
/// [mapJson] is the bundled `renumber_map.json`: `{"layout": 2, "oldToNew": {"33": 41, ...}}`.
/// Files of numbers not in the map (channels removed earlier, e.g. old 23) are deleted: their number may now
/// belong to another channel. The folder's own `channels.json` is moved aside (`channels.json.pre-renumber`) so
/// the app re-seeds it from the bundle.
///
/// Crash-safe, two-phase: phase 1 renames number-keyed files to their new name + `.renum-tmp` (never onto a
/// live name, so swaps and cycles can't collide) and writes rewritten JSON files as `.renum-tmp` beside the
/// untouched originals; then it writes `layout_version.pending`. Phase 2 drops the `.renum-tmp` suffixes and
/// writes `layout_version`. A crash in phase 1 just redoes phase 1 (only files without the suffix still have
/// old numbers); a crash in phase 2 finishes phase 2. Returns a log line, or null when there was nothing to do.
String? migrateLayout(Directory dataDir, String mapJson) {
  final j = jsonDecode(mapJson) as Map<String, dynamic>;
  final layout = j['layout'] as int;
  final map = {for (final e in (j['oldToNew'] as Map<String, dynamic>).entries) int.parse(e.key): e.value as int};
  if (map.values.toSet().length != map.length) throw ArgumentError('renumber map is not one-to-one');

  File f(String name, [String? sub]) => File([dataDir.path, if (sub != null) sub, name].join(Platform.pathSeparator));
  final version = f('layout_version');
  if (version.existsSync() && (int.tryParse(version.readAsStringSync().trim()) ?? 0) >= layout) return null;
  dataDir.createSync(recursive: true);
  try {
    return _migrate(dataDir, layout, map, f, version);
  } on FileSystemException catch (e) {
    // ponytail: a locked/unwritable file mid-move. Pools and days are caches: drop them all (they rebuild,
    // Android re-seeds) rather than risk another channel's pool under a number; settings may keep old numbers.
    for (final sub in ['pools', 'days']) {
      final d = Directory('${dataDir.path}${Platform.pathSeparator}$sub');
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    for (final file in dataDir.listSync().whereType<File>().where((x) => x.path.endsWith('.renum-tmp'))) {
      file.deleteSync();
    }
    version.writeAsStringSync('$layout', flush: true);
    final pending = f('layout_version.pending');
    if (pending.existsSync()) pending.deleteSync();
    return 'channel layout $layout: migration failed ($e); pools and saved days cleared, they rebuild';
  }
}

String _migrate(Directory dataDir, int layout, Map<int, int> map, File Function(String, [String?]) f, File version) {
  final pending = f('layout_version.pending');
  var moved = 0, dropped = 0;

  if (!pending.existsSync()) {
    // Phase 1: pools/pool-N.json, pools/serials-N.json, days/day-N-<date>.json.
    for (final (sub, pattern) in [
      ('pools', RegExp(r'^(pool|serials)-(\d+)(\.json)$')),
      ('days', RegExp(r'^(day)-(\d+)(-\d{4}-\d{2}-\d{2}\.json)$')),
    ]) {
      final dir = Directory('${dataDir.path}${Platform.pathSeparator}$sub');
      if (!dir.existsSync()) continue;
      for (final file in dir.listSync().whereType<File>()) {
        final m = pattern.firstMatch(file.uri.pathSegments.last);
        if (m == null) continue;
        final to = map[int.parse(m.group(2)!)];
        if (to == null) {
          file.deleteSync();
          dropped++;
        } else {
          file.renameSync(f('${m.group(1)}-$to${m.group(3)}.renum-tmp', sub).path);
          moved++;
        }
      }
    }

    int? mapN(Object? n) => n is int ? map[n] : null;
    List<int> mapList(Object? l) => [for (final n in (l as List? ?? const [])) if (mapN(n) case final m?) m]..sort();
    void rewrite(File file, String Function(String text) change) {
      if (!file.existsSync()) return;
      final String out;
      try {
        out = change(file.readAsStringSync());
      } on FormatException {
        return; // corrupt: the app treats it as empty anyway
      }
      File('${file.path}.renum-tmp').writeAsStringSync(out, flush: true);
    }

    rewrite(f('settings.json'), (t) {
      final s = jsonDecode(t) as Map<String, dynamic>;
      if (s['favorites'] is List) s['favorites'] = mapList(s['favorites']);
      if (s.containsKey('lastChannel')) s['lastChannel'] = mapN(s['lastChannel']);
      if (s['parental'] case final Map<String, dynamic> p when p['locked'] is List) p['locked'] = mapList(p['locked']);
      return jsonEncode(s);
    });
    rewrite(f('wrong_items.json'), (t) {
      final w = jsonDecode(t) as Map<String, dynamic>;
      return jsonEncode({
        for (final e in w.entries)
          if (mapN(int.tryParse(e.key)) case final m?) '$m': e.value,
      });
    });
    rewrite(f('wrong_channel.jsonl'), (t) {
      final lines = [
        for (final line in const LineSplitter().convert(t))
          if (line.trim().isNotEmpty)
            () {
              try {
                final r = jsonDecode(line) as Map<String, dynamic>;
                if (mapN(r['channel']) case final m?) r['channel'] = m;
                return jsonEncode(r);
              } on Object {
                return line;
              }
            }(),
      ];
      return lines.isEmpty ? '' : '${lines.join('\n')}\n';
    });
    // The folder's channels.json has the old numbers: set aside, re-seeded from the bundle at startup.
    final config = f('channels.json');
    if (config.existsSync()) config.renameSync(f('channels.json.pre-renumber').path);
    final bundled = f('channels.bundled.json');
    if (bundled.existsSync()) bundled.deleteSync();
    pending.writeAsStringSync('$layout', flush: true);
  }

  // Phase 2.
  for (final dir in [dataDir, Directory('${dataDir.path}${Platform.pathSeparator}pools'), Directory('${dataDir.path}${Platform.pathSeparator}days')]) {
    if (!dir.existsSync()) continue;
    for (final file in dir.listSync().whereType<File>()) {
      if (file.path.endsWith('.renum-tmp')) file.renameSync(file.path.substring(0, file.path.length - '.renum-tmp'.length));
    }
  }
  version.writeAsStringSync('$layout', flush: true);
  pending.deleteSync();
  return 'channel layout $layout: $moved pool/day files renumbered, $dropped of removed channels deleted';
}
