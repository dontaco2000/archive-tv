import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'scheduler.dart';

File _file(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

Object? _readJson(File f) => f.existsSync() ? jsonDecode(f.readAsStringSync()) : null;

void _writeJson(File f, Object value) {
  f.parent.createSync(recursive: true);
  final tmp = File('${f.path}.tmp')..writeAsStringSync(jsonEncode(value));
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

/// Day schedules saved once made, so a pool refresh never rewrites the week
/// the guide already shows. Past days are deleted.
class SnapshotStore {
  final Directory dir;
  SnapshotStore(this.dir);

  File _f(int channel, DateTime day) => _file(dir, 'day-$channel-${dayKey(day)}.json');

  /// The saved schedule for [day], making and saving it from [pool] if absent.
  List<Slot> day(int channel, DateTime day, List<Entry> pool) {
    final f = _f(channel, day);
    final saved = _readJson(f) as List?;
    if (saved != null) {
      return [for (final s in saved.cast<Map<String, dynamic>>()) Slot.fromJson(s)];
    }
    final slots = scheduleDay(pool, 'ch$channel', day);
    if (slots.isNotEmpty) _writeJson(f, [for (final s in slots) s.toJson()]);
    return slots;
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
