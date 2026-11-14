import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'title_cleaner.dart';

/// The Archive item fields that name a programme (from advancedsearch; see `ArchiveClient.itemInfos`).
/// All null = looked up, nothing found (kept so it is not asked again).
class ItemInfo {
  final String identifier;
  final String? title;
  final String? creator;
  final String? date;

  /// Plain text, at most [maxDescription] characters (see [plainDescription]).
  final String? description;

  const ItemInfo(this.identifier, {this.title, this.creator, this.date, this.description});

  Map<String, String> toJson() => {
        if (title != null) 't': title!,
        if (creator != null) 'c': creator!,
        if (date != null) 'd': date!,
        if (description != null) 's': description!,
      };

  factory ItemInfo.fromJson(String id, Map j) =>
      ItemInfo(id, title: j['t'] as String?, creator: j['c'] as String?, date: j['d'] as String?, description: j['s'] as String?);
}

/// What the guides show for one programme. [label] is the one-line form ("Title: Sub").
class ProgrammeInfo {
  final String title;
  final String? subTitle;
  final String? description;
  final DateTime? airDate;

  const ProgrammeInfo(this.title, {this.subTitle, this.description, this.airDate});

  String get label => subTitle == null ? title : '$title: $subTitle';

  @override
  String toString() => description == null ? label : '$label | $description';
}

const maxDescription = 300;

const _generic = {
  'episode', 'ep', 'part', 'pt', 'season', 'series', 'disc', 'disk', 'dvd', 'tape', 'reel', 'chapter', 'track', //
  'title', 'vol', 'volume', 'vts', 'video', 'movie', 'film', 'clip', 'untitled', 'file', 'program', 'programme',
  'segment', 'show', 'no', 'number', 'copy', 'final', 'full', 'raw', 'main', 'feature', 'cd', 'side', 'mp', 'ia', 'ts',
  'access', 'videoplayback', 'rip', 'vhs',
  'jan', 'january', 'feb', 'february', 'mar', 'march', 'apr', 'april', 'may', 'jun', 'june', 'jul', 'july', 'aug',
  'august', 'sep', 'sept', 'september', 'oct', 'october', 'nov', 'november', 'dec', 'december',
};
final _numberish = RegExp(r'^(\d+[a-z]?|s\d+(e\d+)?|e\d+|\d+x\d+|\d+(st|nd|rd|th)|ep\d+|pt\d+|part\d+|vts\d*|v\d+)$');

/// Ids and hashes: 3+ digits mixed with letters ("x44az75", "030689f2423e...", "20170302reel1").
final _idLike = RegExp(r'^(?=(?:\D*\d){3})(?=.*[a-z])[a-z0-9]+$');

Iterable<String> _words(String s) =>
    s.toLowerCase().split(RegExp(r"[^a-z0-9']+")).map((w) => w.replaceAll("'", '')).where((w) => w.isNotEmpty);

/// [cleaned]'s real words (not generic, numbers or ids).
Iterable<String> _real(String cleaned) =>
    _words(cleaned).where((w) => !_generic.contains(w) && !_numberish.hasMatch(w) && !_idLike.hasMatch(w));

/// Whether a cleaned title names something: not only dates, numbers and generic words
/// ("1987-03-12", "Episode 12", "Season 10", "video", "VTS 01 1", "AV-153"): a real word of 3+ letters.
bool titleIsInformative(String cleaned) => _real(cleaned).any((w) => w.length >= 3);

/// The entry's own title is not good enough to show alone: uninformative ([titleIsInformative]) or a
/// lower-case file-name slug ("lostmovie", "cops s 28 e 22"). The guide then prefers the Archive item's title.
bool needsItemInfo(Entry e) {
  final t = cleanTitle(e.title);
  return !titleIsInformative(t) || t == t.toLowerCase();
}

final _ymd = RegExp(r'(?<!\d)((?:19|20)\d\d)[-._ /]?(0[1-9]|1[0-2])[-._ /]?(0[1-9]|[12]\d|3[01])(?!\d)');
final _mdy = RegExp(r'(?<![\d/])(1[0-2]|0?[1-9])[-./](3[01]|[12]\d|0?[1-9])[-./](\d{4}|\d\d)(?![\d/])');
final _digit = RegExp(r'\d');
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthName = r'(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?';
final _dMonY = RegExp(r'(?<!\d)(\d{1,2})(?:st|nd|rd|th)? ' + _monthName + r',? ((?:19|20)\d\d)(?!\d)', caseSensitive: false);
final _monDY = RegExp(_monthName + r' (\d{1,2})(?:st|nd|rd|th)?,? ((?:19|20)\d\d)(?!\d)', caseSensitive: false);

DateTime? _valid(int y, int m, int d) {
  final t = DateTime(y, m, d);
  return t.month == m && t.day == d ? t : null;
}

int _month(String name) => _months.indexWhere((m) => m.toLowerCase() == name.substring(0, 3).toLowerCase()) + 1;

/// The first full date in [s]: "1987-03-12", "19870312", "20240727_0523", "1-17-87", "12/4/1987",
/// "10 October 2005", "March 12, 1987"; else null. Two-digit years: 30-99 are 19xx, else 20xx.
DateTime? dateIn(String? s) {
  if (s == null || !_digit.hasMatch(s)) return null; // every form has digits; the full regexes are slow
  if (_ymd.firstMatch(s) case final m?) return _valid(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  if (_dMonY.firstMatch(s) case final m?) return _valid(int.parse(m[3]!), _month(m[2]!), int.parse(m[1]!));
  if (_monDY.firstMatch(s) case final m?) return _valid(int.parse(m[3]!), _month(m[1]!), int.parse(m[2]!));
  if (_mdy.firstMatch(s) case final m?) {
    var y = int.parse(m[3]!);
    if (y < 100) y += y >= 30 ? 1900 : 2000;
    return _valid(y, int.parse(m[1]!), int.parse(m[2]!));
  }
  return null;
}

/// "Mar 12, 1987".
String formatDate(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// Archive description as plain text: tags and entities out, whitespace collapsed, cut to [maxDescription]
/// characters at a word with "...". Null when empty.
String? plainDescription(String? html) {
  if (html == null) return null;
  var t = html
      .replaceAll(RegExp(r'<(br|/p|/div|/li)[^>]*>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAllMapped(RegExp(r'&(#\d+|amp|lt|gt|quot|apos|nbsp|#39);'), (m) => switch (m[1]!) {
            'amp' => '&',
            'lt' => '<',
            'gt' => '>',
            'quot' => '"',
            'apos' || '#39' => "'",
            'nbsp' => ' ',
            final n => String.fromCharCode(int.tryParse(n.substring(1)) ?? 32),
          })
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.isEmpty) return null;
  if (t.length > maxDescription) {
    final cut = t.lastIndexOf(' ', maxDescription - 3);
    t = '${t.substring(0, cut > maxDescription ~/ 2 ? cut : maxDescription - 3)}...';
  }
  return t;
}

/// "tonight-show-1987-03-12" -> "Tonight Show", "QLSeason1" -> "QL Season 1", "teen-titans_202607" -> "Teen Titans"
/// (dates, 6+ digit stamps and separators out, camel case split, words capitalised).
String _prettyId(String id) => id
    .replaceAll(_ymd, ' ')
    .replaceAllMapped(RegExp(r'(?<=[a-z])(?=[A-Z0-9])|(?<=[A-Z])(?=[A-Z][a-z])|(?<=[0-9])(?=[A-Za-z])'), (_) => ' ')
    .split(RegExp(r'[-_.\s]+'))
    .where((w) => w.isNotEmpty && !RegExp(r'^\d{6,}$').hasMatch(w))
    .map((w) => w[0].toUpperCase() + w.substring(1))
    .join(' ');

/// [_prettyId] for On Demand's show grouping.
String prettyItemId(String id) => _prettyId(id);

/// All-lower-case text capitalised word by word ("keeping up appearances s04e01" -> "Keeping Up Appearances S04E01").
String _caps(String s) => s != s.toLowerCase()
    ? s
    : s.replaceAllMapped(RegExp(r"[a-z0-9']+"), (m) {
        final w = m[0]!;
        return RegExp(r'^s\d+e\d+$').hasMatch(w) ? w.toUpperCase() : w[0].toUpperCase() + w.substring(1);
      });

/// [label] without its leading words that are also in [title] ("blue planet ii 01 one ocean" minus
/// "Blue Planet II" -> "01 one ocean"); null if nothing is left; [label] itself if its first word is not in [title].
String? _after(String label, String title) {
  final t = _words(title).toList(), l = _words(label).toList();
  if (t.join().contains(l.join())) return null; // "AMERICA1900" vs "America 1900", "lostmovie" vs "The Lost Movie"
  final i = l.indexWhere((w) => !t.contains(w)); // "clueless season 02" minus "Clueless (1996-99)": "season 02"
  return switch (i) { -1 => null, 0 => label, _ => l.skip(i).join(' ') };
}

/// Title, sub-title, description and air date for a programme, for every guide (app guide, info banner,
/// On Demand, the server's XMLTV). Display only: never changes the entry.
/// A good file title is kept as is ([item] adds only the description). A date, number, generic or slug title
/// ("1987-03-12", "Episode 12", "lostmovie") becomes the item's title (else its creator; with no item info and no
/// real words, the prettified item id) with the date ("Mar 12, 1987") or the rest of the file label ("Episode 12")
/// as sub-title. All-lower-case results are capitalised.
ProgrammeInfo programmeInfo(Entry e, [ItemInfo? item]) {
  final clean = cleanTitle(e.title);
  final description = plainDescription(item?.description);
  // "20240101 152838": a capture time stamp, not an air date, once the item's own title is known
  final stamp = item?.title != null && RegExp(r'(?:19|20)\d{6}[ _-]?\d{4,6}(?!\d)').hasMatch(clean);
  final fileDate = stamp ? null : dateIn(clean);
  final airDate = fileDate ?? dateIn(item?.date);
  if (!needsItemInfo(e)) return ProgrammeInfo(clean, description: description, airDate: airDate);
  // Archive's own title/creator are written by people: "M*A*S*H Season 3", "Pi" and "1776" count.
  String? named(String? s) => switch (s == null ? null : cleanTitle(s)) {
        final t? when _real(t).join().length >= 2 || RegExp(r'^\d{3,4}$').hasMatch(t) => t,
        _ => null,
      };
  String? pick(String? s) => s != null && titleIsInformative(cleanTitle(s)) ? cleanTitle(s) : null;
  final title = named(item?.title) ??
      (titleIsInformative(clean) ? clean : null) ??
      named(item?.creator) ??
      (_real(clean).join().length < 2 ? pick(_prettyId(cleanTitle(e.itemId))) : null) ?? // not "Pi"
      clean;
  if (title == clean) {
    // nothing better known: a bare date at least reads as one ("01-28-89" -> "Jan 28, 1989")
    final t = fileDate != null && !titleIsInformative(clean)
        ? formatDate(fileDate)
        : _caps(clean.contains(' ') ? clean : clean.replaceAll('-', ' ')); // "an-idiot-abroad" -> "An Idiot Abroad"
    return ProgrammeInfo(t, description: description, airDate: airDate);
  }
  final rest = _after(clean, title);
  String? sub() {
    if (stamp) return null;
    if (fileDate != null) {
      // "conan 2010 11 16 harrison ford" under "CONAN TBS 2010": "Nov 16, 2010 - Harrison Ford"
      final t = _words(title).toSet();
      final extra = rest == null ? '' : _caps(_real(rest).where((w) => !t.contains(w) && dateIn(w) == null).join(' '));
      final date = dateIn(title) == fileDate ? null : formatDate(fileDate); // the title already has it
      return [if (date != null) date, if (extra.isNotEmpty) extra].join(' - ').nullIfEmpty;
    }
    if (rest == null) return null;
    if (RegExp(r'^\d{1,4}$').hasMatch(rest)) return '#${int.parse(rest)}';
    final vts = RegExp(r'^vts \d+ (\d+)$', caseSensitive: false).firstMatch(rest); // DVD title-set file
    if (vts != null) return 'Part ${int.parse(vts[1]!)}';
    // "video", "UNTITLED": the item's date, if any
    if (_real(rest).isEmpty && !rest.contains(RegExp(r'\d'))) return airDate == null ? null : formatDate(airDate);
    return _caps(rest.replaceFirst(RegExp(r'^[\s\-:,.]+'), ''));
  }

  final subTitle = sub();
  return ProgrammeInfo(_caps(title), subTitle: subTitle, description: description, airDate: airDate);
}

extension on String {
  String? get nullIfEmpty => isEmpty ? null : this;
}

/// Splits [ids] into advancedsearch batches of at most [maxIds] whose `identifier:("a" OR "b")` query stays
/// within Archive's 2,048-character q limit.
List<List<String>> idBatches(Iterable<String> ids, {int maxIds = 50, int maxChars = 2048}) {
  final out = <List<String>>[];
  var cur = <String>[];
  for (final id in ids) {
    if (cur.isNotEmpty && (cur.length >= maxIds || idQuery([...cur, id]).length > maxChars)) {
      out.add(cur);
      cur = [];
    }
    cur.add(id);
  }
  if (cur.isNotEmpty) out.add(cur);
  return out;
}

/// advancedsearch query for one [idBatches] batch.
String idQuery(List<String> ids) => 'identifier:(${ids.map((i) => '"$i"').join(' OR ')})';

/// Item titles/creators/dates/descriptions cached on disk (one JSON file in the data folder), fetched once per
/// item in the background. Lookups never block: an item not fetched yet is null (the cleaned file title shows).
/// Holds only the looked-up items (by default the ones [needsItemInfo]), descriptions capped, so it stays small.
class ItemInfoStore {
  final File file;

  /// Fetches one batch (see [idBatches]); ids missing from the answer are stored as "nothing found".
  /// Null: offline, lookups only.
  final Future<List<ItemInfo>> Function(List<String> ids)? fetch;
  final void Function(String)? log;

  Map<String, ItemInfo>? _items;
  Future<int>? _running;

  ItemInfoStore(this.file, {this.fetch, this.log});

  Map<String, ItemInfo> get _map => _items ??= () {
        try {
          final j = jsonDecode(file.readAsStringSync()) as Map;
          return {for (final MapEntry(:key, :value) in j.entries) key as String: ItemInfo.fromJson(key, value as Map)};
        } on Object {
          return <String, ItemInfo>{}; // missing or corrupt: start over
        }
      }();

  ItemInfo? operator [](String itemId) => _map[itemId];

  ProgrammeInfo info(Entry e) => programmeInfo(e, this[e.itemId]);

  int get length => _map.length;

  void _save() {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp')..writeAsStringSync(jsonEncode(_map), flush: true);
    tmp.renameSync(file.path);
  }

  /// Looks up the items of [entries] not cached yet: those that [needsItemInfo], or all with [all] (descriptions
  /// for every programme). [concurrency] batches at a time; failed batches are skipped (retried next call).
  /// [onUpdate] runs after each batch that added something. Returns how many items were added.
  /// A second call while one runs returns the running one.
  Future<int> enrich(Iterable<Entry> entries, {bool all = false, int concurrency = 2, void Function()? onUpdate}) =>
      _running ??= _enrich(entries, all, concurrency, onUpdate).whenComplete(() => _running = null);

  Future<int> _enrich(Iterable<Entry> entries, bool all, int concurrency, void Function()? onUpdate) async {
    final fetch = this.fetch;
    if (fetch == null) return 0;
    final map = _map;
    final ids = <String>{
      for (final e in entries)
        if (!map.containsKey(e.itemId) && (all || needsItemInfo(e))) e.itemId,
    };
    final queue = idBatches(ids);
    var added = 0, sinceSave = 0;
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final batch = queue.removeLast();
        try {
          final got = {for (final i in await fetch(batch)) i.identifier: i};
          for (final id in batch) {
            map[id] = got[id] ?? ItemInfo(id);
          }
          added += batch.length;
          if (++sinceSave >= 10) {
            sinceSave = 0;
            _save();
          }
          onUpdate?.call();
        } on Object catch (e) {
          log?.call('item info: batch of ${batch.length} failed: $e');
        }
      }
    }

    await Future.wait([for (var i = 0; i < concurrency; i++) worker()]);
    if (added > 0) _save();
    return added;
  }
}
