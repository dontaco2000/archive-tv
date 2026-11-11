import 'file_picker.dart';
import 'models.dart';
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
