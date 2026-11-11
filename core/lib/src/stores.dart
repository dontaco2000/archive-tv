import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'scheduler.dart';

File _file(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

/// Null if the file is missing, empty or corrupt (so it gets rebuilt).
Object? _readJson(File f) {
  if (!f.existsSync()) return null;
  try {
    final text = f.readAsStringSync();
    return text.trim().isEmpty ? null : jsonDecode(text);
  } on FormatException {
    return null;
  }
}

void _writeJson(File f, Object value) {
  f.parent.createSync(recursive: true);
  final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(value), flush: true);
  tmp.renameSync(f.path); // never leave a half-written file behind
}

/// Saved content pools, one file per channel.
class PoolStore {
  final Directory dir;
  PoolStore(this.dir);

  File _f(int channel) => _file(dir, 'pool-$channel.json');

  void save(int channel, List<Entry> pool) => _writeJson(_f(channel), {
        'builtAt': DateTime.now().toIso8601String(),
        'entries': [for (final e in pool) e.toJson()],
      });

  /// The saved pool, or null if none yet.
  List<Entry>? load(int channel) {
    final j = _readJson(_f(channel)) as Map<String, dynamic>?;
    if (j == null) return null;
    return [for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) Entry.fromJson(e)];
  }

  /// How old the saved pool is, or null if none.
  Duration? age(int channel) {
    final j = _readJson(_f(channel)) as Map<String, dynamic>?;
    if (j == null) return null;
    return DateTime.now().difference(DateTime.parse(j['builtAt'] as String));
  }
}

/// Each day's shuffled entry order, saved once made, so a pool refresh never
/// reshuffles the week the guide already shows. Saving the order (not finished
/// slots) keeps days editable: a blocked item drops out and later times shift.
/// Past days are deleted.
class SnapshotStore {
  final Directory dir;
  SnapshotStore(this.dir);

  final Map<String, List<Entry>> _orders = {}; // '<channel>-<dayKey>' -> unfiltered day order

  File _f(int channel, DateTime day) => _file(dir, 'day-$channel-${dayKey(day)}.json');

  /// The schedule for [day] (a local DateTime), from the saved order, making
  /// and saving it from [pool] if absent; [blocklist] entries are removed.
  List<Slot> day(int channel, DateTime day, List<Entry> pool, {Blocklist? blocklist}) {
    final key = '$channel-${dayKey(day)}';
    var order = _orders[key];
    if (order == null) {
      final f = _f(channel, day);
      final saved = _readJson(f) as List?;
      order = saved != null
          ? [for (final e in saved.cast<Map<String, dynamic>>()) Entry.fromJson(e)]
          : dayOrder(pool, 'ch$channel', day);
      if (saved == null && order.isNotEmpty) _writeJson(f, [for (final e in order) e.toJson()]);
      if (order.isNotEmpty) _orders[key] = order; // empty days are not cached: the pool may fill later
    }
    if (blocklist != null) order = blocklist.apply(order);
    return layoutDay(order, day);
  }

  /// Makes sure today and the next [days] - 1 days are saved.
  void ensureWeek(int channel, DateTime today, List<Entry> pool, {int days = 7}) {
    for (var i = 0; i < days; i++) {
      day(channel, DateTime(today.year, today.month, today.day + i), pool);
    }
  }

  /// Deletes snapshot files for days before [today].
  void prune(DateTime today) {
    if (!dir.existsSync()) return;
    final cutoff = dayKey(today);
    _orders.removeWhere((k, _) => k.substring(k.indexOf('-') + 1).compareTo(cutoff) < 0);
    for (final f in dir.listSync().whereType<File>()) {
      final m = RegExp(r'day-\d+-(\d{4}-\d{2}-\d{2})\.json$').firstMatch(f.path);
      if (m != null && m.group(1)!.compareTo(cutoff) < 0) f.deleteSync();
    }
  }
}

/// Entry ids the user blocked ("never play this"), kept across rebuilds.
class Blocklist {
  final File _f;
  final Set<String> ids;

  Blocklist._(this._f, this.ids);

  factory Blocklist.load(Directory dir) {
    final f = _file(dir, 'blocked.json');
    final saved = (_readJson(f) as List?)?.cast<String>() ?? const <String>[];
    return Blocklist._(f, {...saved});
  }

  void add(String id) {
    ids.add(id);
    _writeJson(_f, ids.toList()..sort());
  }

  /// [pool] without blocked entries (matched by entry id or by whole item id).
  List<Entry> apply(List<Entry> pool) =>
      [for (final e in pool) if (!ids.contains(e.id) && !ids.contains(e.itemId)) e];
}
