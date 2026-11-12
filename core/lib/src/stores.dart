import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'scheduler.dart';
import 'serials.dart';

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

  /// [builtAt] (default now) is when the pool was built, e.g. for a seeded pool.
  void save(int channel, List<Entry> pool, {DateTime? builtAt}) => _writeJson(_f(channel), {
        'builtAt': (builtAt ?? DateTime.now()).toIso8601String(),
        'entries': [for (final e in pool) e.toJson()],
      });

  /// The saved pool, or null if none yet.
  List<Entry>? load(int channel) {
    final j = _readJson(_f(channel)) as Map<String, dynamic>?;
    if (j == null) return null;
    return [for (final e in (j['entries'] as List).cast<Map<String, dynamic>>()) Entry.fromJson(e)];
  }

  File _s(int channel) => _file(dir, 'serials-$channel.json');

  /// Saves [c]'s serial episode lists (`[slot][show]`), tagged with its [serialsSignature].
  void saveSerials(Channel c, List<List<List<Entry>>> episodes) => _writeJson(_s(c.number), {
        'signature': serialsSignature(c),
        'slots': [
          for (final slot in episodes) [for (final show in slot) [for (final e in show) e.toJson()]],
        ],
      });

  /// The saved serial episode lists, or null if none or saved for a different serial config.
  List<List<List<Entry>>>? loadSerials(Channel c) {
    final j = _readJson(_s(c.number)) as Map<String, dynamic>?;
    if (j == null || j['signature'] != serialsSignature(c)) return null;
    return [
      for (final slot in (j['slots'] as List).cast<List>())
        [
          for (final show in slot.cast<List>()) [for (final e in show.cast<Map<String, dynamic>>()) Entry.fromJson(e)],
        ],
    ];
  }

  /// How old the saved pool is, or null if none.
  Duration? age(int channel) {
    // `builtAt` is written first: read the file's head, not the whole (up to 2 MB) pool.
    final f = _f(channel);
    if (!f.existsSync()) return null;
    final raf = f.openSync();
    final String head;
    try {
      head = latin1.decode(raf.readSync(80));
    } finally {
      raf.closeSync();
    }
    final m = RegExp(r'^\{"builtAt":"([^"]+)"').firstMatch(head);
    if (m != null) return DateTime.now().difference(DateTime.parse(m.group(1)!));
    final j = _readJson(f) as Map<String, dynamic>?;
    if (j == null) return null;
    return DateTime.now().difference(DateTime.parse(j['builtAt'] as String));
  }
}

/// Each day's shuffled entry order, saved once made, so a pool refresh never
/// reshuffles the week the guide already shows. Saving the order (not finished
/// slots) keeps days editable: a blocked item drops out and later times shift.
/// Past days are deleted. A day with serial blocks also saves the blocks' episode picks
/// (`{"order": [...], "serials": [...]}`; a day without is the plain order list).
class SnapshotStore {
  final Directory dir;
  SnapshotStore(this.dir);

  // '<channel>-<dayKey>' -> unfiltered day order and serial blocks
  final Map<String, (List<Entry>, List<SerialBlock>)> _days = {};

  File _f(int channel, DateTime day) => _file(dir, 'day-$channel-${dayKey(day)}.json');

  static (List<Entry>, List<SerialBlock>)? _read(File f) {
    List<Entry> entries(Object? l) => [for (final e in (l as List).cast<Map<String, dynamic>>()) Entry.fromJson(e)];
    return switch (_readJson(f)) {
      final List l => (entries(l), const []),
      final Map m => (
          entries(m['order']),
          [for (final b in (m['serials'] as List? ?? const []).cast<Map<String, dynamic>>()) SerialBlock.fromJson(b)]
        ),
      _ => null,
    };
  }

  /// The schedule for [day] (a local DateTime), from the saved order, making
  /// and saving it from [pool] if absent; [blocklist] entries are removed.
  /// [serials] gives the day's serial blocks; they are saved with the day the first time
  /// they are non-empty (also for a day saved before the channel had serials).
  /// [inShuffle] filters the saved order (e.g. drops rare-source entries from a day saved before
  /// the source got `perDay`); block episodes are not filtered by it.
  List<Slot> day(int channel, DateTime day, List<Entry> pool,
      {Blocklist? blocklist, List<SerialBlock> Function(DateTime day)? serials, bool Function(Entry)? inShuffle}) {
    final key = '$channel-${dayKey(day)}';
    final f = _f(channel, day);
    var snap = _days[key];
    if (snap == null) {
      snap = _read(f);
      // A saved day is a whole shuffled pool: share the pool's Entry objects instead of keeping a second
      // copy of every entry per day (49 channels x 7 days of copies ran a 1 GB Fire Stick out of memory).
      if (snap != null) {
        final byId = {for (final e in pool) e.id: e};
        Entry same(Entry e) => byId[e.id] ?? e;
        snap = (
          [for (final e in snap.$1) same(e)],
          [for (final b in snap.$2) b.withEpisodes([for (final e in b.episodes) same(e)])]
        );
      }
    }
    var dirty = false;
    if (snap == null) {
      snap = (dayOrder(pool, 'ch$channel', day), const <SerialBlock>[]);
      dirty = true;
    }
    if (snap.$2.isEmpty && serials != null) {
      final blocks = serials(day);
      if (blocks.isNotEmpty) {
        snap = (snap.$1, blocks);
        dirty = true;
      }
    }
    final (saved, blocks) = snap;
    final order = inShuffle == null ? saved : saved.where(inShuffle).toList();
    if (order.isNotEmpty || blocks.isNotEmpty) {
      _days[key] = snap; // empty days are not cached: the pool may fill later
      if (dirty) {
        _writeJson(
            f,
            blocks.isEmpty
                ? [for (final e in saved) e.toJson()]
                : {
                    'order': [for (final e in saved) e.toJson()],
                    'serials': [for (final b in blocks) b.toJson()],
                  });
      }
    }
    if (blocklist == null) return layoutSerialDay(order, day, blocks);
    return layoutSerialDay(
        blocklist.apply(order), day, [for (final b in blocks) b.withEpisodes(blocklist.apply(b.episodes))]);
  }

  /// Makes sure today and the next [days] - 1 days are saved.
  void ensureWeek(int channel, DateTime today, List<Entry> pool,
      {int days = 7, List<SerialBlock> Function(DateTime day)? serials}) {
    for (var i = 0; i < days; i++) {
      final d = DateTime(today.year, today.month, today.day + i);
      // A saved day needs no reading unless serial blocks may have to be added to it.
      if (serials == null && _f(channel, d).existsSync()) continue;
      day(channel, d, pool, serials: serials);
    }
  }

  /// Forgets [channel]'s saved days after [today] (a new pool came in): they are made again from the new
  /// pool when next asked for. Today's day stays, so what is airing now doesn't jump.
  void dropAfter(int channel, DateTime today) {
    final cutoff = dayKey(today);
    _days.removeWhere((k, _) => k.startsWith('$channel-') && k.substring(k.indexOf('-') + 1).compareTo(cutoff) > 0);
    if (!dir.existsSync()) return;
    for (final f in dir.listSync().whereType<File>()) {
      final m = RegExp(r'day-(\d+)-(\d{4}-\d{2}-\d{2})\.json$').firstMatch(f.path);
      if (m != null && m.group(1) == '$channel' && m.group(2)!.compareTo(cutoff) > 0) f.deleteSync();
    }
  }

  /// Deletes snapshot files for days before [today].
  void prune(DateTime today) {
    if (!dir.existsSync()) return;
    final cutoff = dayKey(today);
    _days.removeWhere((k, _) => k.substring(k.indexOf('-') + 1).compareTo(cutoff) < 0);
    for (final f in dir.listSync().whereType<File>()) {
      final m = RegExp(r'day-\d+-(\d{4}-\d{2}-\d{2})\.json$').firstMatch(f.path);
      if (m != null && m.group(1)!.compareTo(cutoff) < 0) f.deleteSync();
    }
  }
}

/// Entry ids the user blocked ("never play this"), kept across rebuilds.
class Blocklist {
  final File? _f; // null: in-memory only
  final Set<String> ids;

  Blocklist._(this._f, this.ids);

  /// In-memory list (nothing is written), e.g. items that failed to play this session.
  Blocklist.session() : this._(null, {});

  /// A new in-memory list holding the ids of both; later adds to either are not reflected.
  Blocklist union(Blocklist other) => Blocklist._(null, {...ids, ...other.ids});

  /// The list saved as [name] in [dir] (the viewer's blocks by default).
  factory Blocklist.load(Directory dir, {String name = 'blocked.json'}) {
    final f = _file(dir, name);
    final saved = (_readJson(f) as List?)?.cast<String>() ?? const <String>[];
    return Blocklist._(f, {...saved});
  }

  void add(String id) {
    ids.add(id);
    final f = _f;
    if (f != null) _writeJson(f, ids.toList()..sort());
  }

  /// [pool] without blocked entries (matched by entry id or by whole item id).
  List<Entry> apply(List<Entry> pool) =>
      [for (final e in pool) if (!ids.contains(e.id) && !ids.contains(e.itemId)) e];
}

/// Ids the viewer marked "wrong channel": kept off that one channel only. Saved as
/// `{"<channel>": ["<item id>", ...]}`; a missing or malformed file reads as empty.
class ChannelBlocklist {
  final File _f;
  final Map<int, Set<String>> ids;

  ChannelBlocklist._(this._f, this.ids);

  factory ChannelBlocklist.load(Directory dir, {String name = 'wrong_items.json'}) {
    final f = _file(dir, name);
    final ids = <int, Set<String>>{};
    if (_readJson(f) case final Map m) {
      for (final MapEntry(:key, :value) in m.entries) {
        final n = int.tryParse('$key');
        if (n != null && value is List) ids[n] = {...value.whereType<String>()};
      }
    }
    return ChannelBlocklist._(f, ids);
  }

  void add(int channel, String id) {
    (ids[channel] ??= {}).add(id);
    _writeJson(_f, {for (final MapEntry(:key, :value) in ids.entries) '$key': value.toList()..sort()});
  }

  /// The ids blocked on [channel], as a read-only-by-convention [Blocklist] (never add to it).
  Blocklist forChannel(int channel) => Blocklist._(null, ids[channel] ?? const {});
}
