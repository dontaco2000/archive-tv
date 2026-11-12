import 'dart:convert';

import 'config.dart' show ConfigException;
import 'models.dart';

/// Local time-of-day window in which R-rated entries may air: [startMinute] to [endMinute] (minutes after
/// local midnight). Start after end wraps past midnight (22:00-05:00 = 22:00-24:00 plus 00:00-05:00).
/// Start == end: no restriction (any time).
class RatedWindow {
  final int startMinute;
  final int endMinute;

  const RatedWindow(this.startMinute, this.endMinute);

  static const always = RatedWindow(0, 0);

  bool get unrestricted => startMinute == endMinute;

  /// An entry [length] long may start at [start] (local): it starts inside the window and ends by its end.
  bool allows(DateTime start, Duration length) {
    if (unrestricted) return true;
    final m = start.hour * 3600 + start.minute * 60 + start.second;
    final end = m + length.inSeconds;
    final s = startMinute * 60, e = endMinute * 60;
    if (s < e) return m >= s && end <= e;
    return (m >= s && end <= e + 86400) || (m < e && end <= e);
  }

  /// Whether local time [t] is inside the window (On Demand: "is it night now?").
  bool contains(DateTime t) => allows(t, Duration.zero);
}

/// `rated.json`: what is known to be R-rated (or harsher), and when it may air.
class RatedRules {
  final RatedWindow window;

  /// Archive item ids, or entry ids (`item/file`) for one file of an item.
  final Set<String> identifiers;

  /// Case-insensitive title patterns (e.g. `\b(unrated|uncensored)\b`).
  final List<RegExp> titlePatterns;

  const RatedRules({this.window = const RatedWindow(22 * 60, 5 * 60), this.identifiers = const {}, this.titlePatterns = const []});
}

/// Parses `rated.json`: `{"window": {"start": "22:00", "end": "05:00"}, "identifiers": {"item id": "note", ...},
/// "titlePatterns": ["regex", ...]}`. `identifiers` may also be a plain list.
RatedRules parseRatedRules(String jsonText) {
  final Object? j;
  try {
    j = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw ConfigException('rated.json is not valid JSON: ${e.message}');
  }
  if (j is! Map<String, dynamic>) throw ConfigException('rated.json must be a JSON object');
  final ids = switch (j['identifiers']) {
    null => const <String>{},
    final Map m => {for (final k in m.keys) k as String},
    final List l => {for (final x in l) x as String},
    _ => throw ConfigException('rated.json "identifiers" must be an object or a list'),
  };
  return RatedRules(
    window: j.containsKey('window') ? parseRatedWindow(j['window'], 'rated.json window') : const RatedRules().window,
    identifiers: ids,
    titlePatterns: [for (final p in (j['titlePatterns'] as List? ?? const [])) _pattern(p)],
  );
}

RegExp _pattern(Object? p) {
  if (p is! String) throw ConfigException('rated.json "titlePatterns" must be strings');
  try {
    return RegExp(p, caseSensitive: false);
  } on FormatException catch (e) {
    throw ConfigException('rated.json title pattern "$p" is not a valid regex: ${e.message}');
  }
}

/// `{"start": "22:00", "end": "05:00"}`, or null for no restriction ([RatedWindow.always]).
RatedWindow parseRatedWindow(Object? raw, String what) {
  if (raw == null) return RatedWindow.always;
  if (raw is! Map<String, dynamic>) throw ConfigException('$what must be like {"start": "22:00", "end": "05:00"} or null');
  int clock(Object? v) {
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('$v');
    final h = int.tryParse(m?.group(1) ?? ''), min = int.tryParse(m?.group(2) ?? '');
    if (h == null || min == null || h > 24 || min > 59 || (h == 24 && min > 0)) throw ConfigException('$what times must be like "22:00"');
    return (h * 60 + min) % 1440;
  }

  return RatedWindow(clock(raw['start']), clock(raw['end']));
}

/// Archive `rating` metadata that means R or harsher ("R", "R;L", "NC-17", "X", "TV-MA"). Seen on some items;
/// most have none.
bool isAdultRating(String? rating) =>
    rating != null && RegExp(r'^\s*(r|nc-17|x|tv-ma)\b', caseSensitive: false).hasMatch(rating);

/// [c]'s effective window: its own `ratedWindow`, else the global one from rated.json.
RatedWindow ratedWindowOf(Channel c, ChannelConfig config) => c.ratedWindow ?? config.rated.window;

/// Whether [e] (on channel [c]) is known to be R-rated: from Archive metadata at build ([Entry.rated]), its
/// source's `"rated"` flag (needs the source tag, set at build), or rated.json ids/title patterns (checked
/// now, so list changes need no rebuild). Results are cached per Entry object.
bool Function(Entry) ratedTest(Channel c, ChannelConfig config) {
  final r = config.rated;
  final cache = Expando<bool>();
  bool test(Entry e) {
    final i = e.source;
    return e.rated != null ||
        (i != null && i >= 0 && i < c.sources.length && c.sources[i].rated != null) ||
        r.identifiers.contains(e.itemId) ||
        r.identifiers.contains(e.id) ||
        r.titlePatterns.any((p) => p.hasMatch(e.title));
  }

  return (e) => cache[e] ??= test(e);
}
