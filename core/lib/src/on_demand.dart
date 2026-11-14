import 'file_picker.dart';
import 'models.dart';
import 'programme_info.dart';
import 'title_cleaner.dart';

int _byTitle(Entry a, Entry b) => naturalCompare(cleanTitle(a.title).toLowerCase(), cleanTitle(b.title).toLowerCase());

/// A key that sorts like [naturalCompare] with a plain string compare ("ep 2" before "ep 10"):
/// lowercased, digit runs zero-padded. Cheap enough to precompute for a whole catalog.
String naturalKey(String s) => s.toLowerCase().replaceAllMapped(RegExp(r'\d+'), (m) => m[0]!.padLeft(10, '0'));

/// Entries whose cleaned title contains [query] (case-insensitive), sorted by title.
/// A blank query returns every entry.
List<Entry> searchTitles(Iterable<Entry> entries, String query) {
  final q = query.trim().toLowerCase();
  final hits = <(String, Entry)>[
    for (final e in entries)
      if (cleanTitle(e.title) case final t when q.isEmpty || t.toLowerCase().contains(q)) (naturalKey(t), e),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final h in hits) h.$2];
}

final _episodeToken = RegExp(r'\b(s\d+\s*e\d+|\d+x\d+|ep(isode)?\.?\s*\d+|\d+)', caseSensitive: false);

/// The series part of a title: lowercased, cut before the first episode code or number,
/// trailing separators dropped. Empty when the title starts with the number.
String seriesName(String title) {
  final t = cleanTitle(title).toLowerCase();
  final m = _episodeToken.firstMatch(t);
  return (m == null ? t : t.substring(0, m.start)).replaceAll(RegExp(r'[\s\-_.:,#(\[]+$'), '').trim();
}

/// What to play after [current] in On Demand: the next file of the same Archive item (natural
/// file order), else best effort across items: the next title of the same series. Null if none.
Entry? nextEpisode(List<Entry> pool, Entry current) {
  final siblings = [for (final e in pool) if (e.itemId == current.itemId) e]..sort((a, b) => naturalCompare(a.file, b.file));
  final i = siblings.indexWhere((e) => e.id == current.id);
  if (i >= 0 && i + 1 < siblings.length) return siblings[i + 1];

  final series = seriesName(current.title);
  if (series.length < 3) return null; // too little to tell one show from another
  final later = [
    for (final e in pool)
      if (e.itemId != current.itemId && seriesName(e.title) == series && _byTitle(e, current) > 0) e,
  ]..sort(_byTitle);
  return later.firstOrNull;
}

// ---- Shows: On Demand's genre -> show -> episode browsing.

/// One show of On Demand: a display [name] and its episodes in natural order.
class ShowGroup {
  final String name;
  final List<Entry> entries;
  const ShowGroup(this.name, this.entries);

  @override
  String toString() => '$name (${entries.length})';
}

/// [groupShows]' answer: the shows (2+ entries each, by name) and the single films / one-offs.
class ShowList {
  final List<ShowGroup> shows;
  final List<Entry> singles;
  const ShowList(this.shows, this.singles);
}

/// Trailing separators and generic words left after cutting a title at its episode code
/// ("Rhoda - " -> "Rhoda", "QL Season " -> "QL", "Recess Complete Series" -> "Recess").
final _seriesTail = RegExp(
    r'([\s\-_.:,;#(\[+]+|\b(part|pt|season|series|complete|full|collection|episodes?|ep|vol|volume|disc|disk|tape|dvd|box set|remastered|the)\b)+$',
    caseSensitive: false);

/// The series part of a cleaned title with its case kept ("Gargoyles S01E03 Awakening" -> "Gargoyles",
/// "Doctor Who - 1974 - 03" -> "Doctor Who", "Soap 2x05" -> "Soap"); the whole title when it has no number.
String _prefix(String clean) {
  var end = clean.length;
  for (final r in [_episodeToken, _seriesCut]) {
    final m = r.firstMatch(clean);
    if (m != null && m.start < end) end = m.start;
  }
  return clean.substring(0, end).replaceFirst(_seriesTail, '').replaceAll(_quotes, '').trim();
}

/// Also ends a series name: a bracket ("Baywatch(The Complete Series)", "ABC TV Sign Off (ABN-2, ...") or a
/// spelled-out date ("All My Children (December 8, 1986)", "Days of Our Lives November 8 1965").
final _seriesCut = RegExp(
    r'\(|\b(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec)\.?\s+\d',
    caseSensitive: false);
final _quotes = RegExp('^[\'"‘’“”]+|[\'"‘’“”]+\$');

/// Grouping key: lower case, punctuation out, "&" = "and", no leading "the".
String _norm(String s) =>
    s.toLowerCase().replaceAll('&', ' and ').replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim().replaceFirst(RegExp(r'^the '), '');

/// "keeping up appearances" -> "Keeping Up Appearances"; mixed case is kept.
String _caps(String s) =>
    s != s.toLowerCase() ? s : s.replaceAllMapped(RegExp(r"[a-z][a-z0-9']*"), (m) => m[0]![0].toUpperCase() + m[0]!.substring(1));

/// Sort key of an episode inside its show: a full date in the title sorts by date, else the title after the
/// show's name in natural order ("S01E02" before "S01E10"); the file id breaks ties.
String _episodeKey(Entry e, String clean, String prefix) {
  final d = dateIn(clean);
  if (d != null) return 'a${d.toIso8601String()}|${naturalKey(e.id)}';
  final rest = clean.toLowerCase().startsWith(prefix.toLowerCase()) ? clean.substring(prefix.length) : clean;
  return 'b${naturalKey(rest.replaceFirst(RegExp(r'^[\s\-:,.]+'), ''))}|${naturalKey(e.id)}';
}

final _year = RegExp(r'^((19|20)\d\d)?$');
final _dashPrefix =RegExp(r'^(.+?)\s+-\s+|^(.+?):\s');

/// Groups On Demand entries into shows. Each entry's show is the series part of its cleaned title (cut before
/// the first episode code or number); a title with no usable series part ("S01E03 - Flushed", "Episode 22",
/// "1987-03-12") uses its Archive item's name ([itemInfo]'s title, else the prettified item id). The same show
/// spread over several items (or channels) merges by name. Entries left alone then try the part before " - " / ": "
/// ("Tex Avery - Bad Luck Blackie"), then their item (2+ leftovers of one item = a show named after the item).
/// What is still alone, plus repeated uploads of one film, goes to [ShowList.singles]. Entries are de-duplicated
/// by id. ponytail: title heuristics, no metadata; known misses are listed in _build\b13_ondemand-report.md.
ShowList groupShows(Iterable<Entry> entries, {ItemInfo? Function(String itemId)? itemInfo}) {
  final itemNames = <String, String?>{};
  String? itemSeries(String id) => itemNames.putIfAbsent(id, () {
        final t = itemInfo?.call(id)?.title;
        final name = t != null && titleIsInformative(cleanTitle(t)) ? cleanTitle(t) : prettyItemId(cleanTitle(id));
        final p = _prefix(name);
        if (titleIsInformative(p)) return p;
        final whole = name.replaceFirst(RegExp(r'[\s\d\-_.()]+$'), '').replaceFirst(_seriesTail, '').trim();
        return titleIsInformative(whole) ? whole : null;
      });

  final groups = <String, List<(Entry, String)>>{}; // key -> (entry, series name as written)
  final loose = <(Entry, String)>[]; // no usable series name at all
  final cleanOf = <String, String>{}; // entry id -> cleanTitle (the regexes are the cost here)
  for (final e in entries) {
    if (cleanOf.containsKey(e.id)) continue;
    final clean = cleanOf[e.id] = cleanTitle(e.title);
    final p = _prefix(clean);
    final s = titleIsInformative(p) ? p : itemSeries(e.itemId);
    if (s == null) {
      loose.add((e, clean));
    } else {
      (groups[_norm(s)] ??= []).add((e, s));
    }
  }

  // Alone so far: " - " prefixes, then their item, may still find company.
  var alone = [
    for (final k in [...groups.keys])
      if (groups[k]!.length == 1) groups.remove(k)!.single,
    ...loose,
  ];
  void regroup(String? Function(Entry) by) {
    final cand = <String, List<(Entry, String)>>{};
    final rest = <(Entry, String)>[];
    for (final x in alone) {
      final s = by(x.$1);
      if (s == null || !titleIsInformative(s)) {
        rest.add(x);
      } else {
        (cand[_norm(s)] ??= []).add((x.$1, s));
      }
    }
    final back = {for (final x in alone) x.$1.id: x};
    for (final MapEntry(:key, :value) in cand.entries) {
      if (groups.containsKey(key) || value.length >= 2) {
        (groups[key] ??= []).addAll(value);
      } else {
        rest.add(back[value.single.$1.id]!);
      }
    }
    alone = rest;
  }

  regroup((e) => switch (_dashPrefix.firstMatch(cleanOf[e.id]!)) { final m? => (m[1] ?? m[2])!.trim(), _ => null });
  final perItem = <String, int>{};
  for (final x in alone) {
    perItem[x.$1.itemId] = (perItem[x.$1.itemId] ?? 0) + 1;
  }
  regroup((e) => perItem[e.itemId]! >= 2 ? itemSeries(e.itemId) : null);

  final singles = [for (final x in alone) x.$1];
  final shows = <ShowGroup>[];
  for (final members in groups.values) {
    // Films, not a show: every title is the name with at most a year ("Dawn of the Dead", "Dawn Of The Dead 1978",
    // "A Christmas Carol (1910)"). They are singles, one per year (repeated uploads of one film shown once).
    final years = <String>{};
    final films = [
      for (final (e, p) in members)
        if (_norm(cleanOf[e.id]!) case final t when t.startsWith(_norm(p)) && _year.hasMatch(t.substring(_norm(p).length).trim()))
          (e, t.substring(_norm(p).length).trim()),
    ];
    if (films.length == members.length) {
      for (final (e, y) in films) {
        if (years.add(y)) singles.add(e);
      }
      continue;
    }
    final counts = <String, int>{};
    for (final (_, p) in members) {
      counts[p] = (counts[p] ?? 0) + 1;
    }
    // The most used spelling, mixed case first ("All My Children" over "ALL MY CHILDREN").
    int score(MapEntry<String, int> c) => c.value + (c.key == c.key.toUpperCase() || c.key == c.key.toLowerCase() ? 0 : 1 << 20);
    final name = _caps(counts.entries.reduce((a, b) => score(b) > score(a) ? b : a).key);
    final sorted = [for (final (e, p) in members) (_episodeKey(e, cleanOf[e.id]!, p), e)]..sort((a, b) => a.$1.compareTo(b.$1));
    shows.add(ShowGroup(name, [for (final s in sorted) s.$2]));
  }
  shows.sort((a, b) => naturalKey(a.name).compareTo(naturalKey(b.name)));
  final keyed = [for (final e in singles) (naturalKey(cleanOf[e.id]!), e)]..sort((a, b) => a.$1.compareTo(b.$1));
  return ShowList(shows, [for (final k in keyed) k.$2]);
}

/// An episode's row text inside its show: [label] without a leading [show] name
/// ("Gargoyles S01E03 Awakening" in "Gargoyles" -> "S01E03 Awakening"); [label] if nothing would be left.
String episodeLabel(String show, String label) {
  if (!label.toLowerCase().startsWith(show.toLowerCase())) return label;
  final rest = label.substring(show.length).replaceFirst(RegExp(r'^[\s\-:,.]+'), '');
  return rest.isEmpty ? label : rest;
}

/// [items] whose [text] contains [query] (case-insensitive), those with a word starting with it first;
/// order otherwise kept. A blank query matches nothing.
List<T> rankMatches<T>(Iterable<T> items, String Function(T) text, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return [];
  final word = <T>[], rest = <T>[];
  for (final x in items) {
    final t = text(x).toLowerCase();
    if (t.startsWith(q) || t.contains(' $q')) {
      word.add(x);
    } else if (t.contains(q)) {
      rest.add(x);
    }
  }
  return [...word, ...rest];
}
