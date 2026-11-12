import 'dart:convert';

import 'models.dart';

/// Thrown for a bad `channels.json`; [message] is shown on screen.
class ConfigException implements Exception {
  final String message;
  ConfigException(this.message);

  @override
  String toString() => 'ConfigException: $message';
}

/// Parses and validates the text of `channels.json`.
ChannelConfig parseChannelConfig(String jsonText) {
  try {
    return _parse(jsonText);
  } on TypeError catch (e) {
    throw ConfigException('channels.json has a value of the wrong type: $e');
  }
}

ChannelConfig _parse(String jsonText) {
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException catch (e) {
    throw ConfigException('channels.json is not valid JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw ConfigException('channels.json must be a JSON object');
  }

  final globalRange = _range(decoded['yearRange'], 'yearRange') ?? const YearRange(1980, 2010);
  final fallbackStart = _int(decoded['fallbackStart'], 'fallbackStart') ?? 1960;
  final minContentSeconds =
      ((_num(decoded['minContentHours'], 'minContentHours') ?? 2) * 3600).round();

  final rawChannels = decoded['channels'];
  if (rawChannels is! List || rawChannels.isEmpty) {
    throw ConfigException('"channels" must be a non-empty list');
  }

  final seen = <int>{};
  final channels = <Channel>[];
  for (final raw in rawChannels) {
    if (raw is! Map<String, dynamic>) {
      throw ConfigException('each channel must be a JSON object');
    }
    final number = _int(raw['number'], 'channel number');
    if (number == null || number < 1) {
      throw ConfigException('every channel needs a "number" of 1 or more');
    }
    if (!seen.add(number)) {
      throw ConfigException('channel number $number is used twice');
    }
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) {
      throw ConfigException('channel $number needs a "name"');
    }
    final type = (raw['type'] as String?) ?? 'archive';
    if (type != 'archive' && type != 'weatherstar') {
      throw ConfigException('channel $number has unknown type "$type"');
    }
    // Archive channels need sources; a weatherstar channel may list some for its background music.
    final rawSources = raw['sources'];
    if (type == 'archive' && (rawSources is! List || rawSources.isEmpty)) {
      throw ConfigException('channel $number ($name) needs at least one source');
    }
    final sources = [for (final s in (rawSources as List? ?? const [])) _source(s, number)];
    final primeTime = _primeTime(raw['primeTime'], number);
    channels.add(Channel(
      primeTime: primeTime,
      serials: _serials(raw['serials'], primeTime, number),
      number: number,
      name: name.trim(),
      genre: (raw['genre'] as String?) ?? '',
      type: type,
      sources: sources,
      yearRange: _range(raw['yearRange'], 'channel $number yearRange'),
      logo: raw['logo'] as String?,
      location: raw['location'] as String?,
      shortContent: raw['shortContent'] as String?,
    ));
  }

  return ChannelConfig(
    yearRange: globalRange,
    fallbackStart: fallbackStart,
    minContentSeconds: minContentSeconds,
    channels: channels,
    excludeIdentifiers: {
      for (final x in (decoded['excludeIdentifiers'] as List? ?? const [])) x as String,
    },
    blockCollections: [
      for (final x in (decoded['blockCollections'] as List? ?? const [])) x as String,
    ],
  );
}

Source _source(Object? raw, int channel) {
  if (raw is! Map<String, dynamic>) {
    throw ConfigException('channel $channel: each source must be a JSON object');
  }
  final query = raw['query'] as String?;
  final collection = raw['collection'] as String?;
  final ids = [for (final x in (raw['identifiers'] as List? ?? const [])) x as String];
  final given = [query != null, collection != null, ids.isNotEmpty].where((b) => b).length;
  if (given != 1) {
    throw ConfigException(
        'channel $channel: a source needs exactly one of "query", "collection" or "identifiers"');
  }
  return Source(
    query: query,
    collection: collection,
    identifiers: ids,
    minDownloads: _int(raw['minDownloads'], 'minDownloads'),
    ignoreYear: (raw['ignoreYear'] as bool?) ?? false,
    mediatype: (raw['mediatype'] as String?) ?? 'movies',
  );
}

PrimeTime _primeTime(Object? raw, int channel) {
  if (raw == null) return const PrimeTime();
  if (raw is! Map<String, dynamic>) throw ConfigException('channel $channel: "primeTime" must be a JSON object');
  final start = raw['start'] == null ? 18 * 60 : _clock(raw['start'], 'channel $channel primeTime start');
  final slots = _int(raw['slots'], 'primeTime slots') ?? 6;
  final minutes = _int(raw['slotMinutes'], 'primeTime slotMinutes') ?? 60;
  if (slots < 1 || minutes < 1) throw ConfigException('channel $channel: primeTime needs slots and slotMinutes of 1 or more');
  return PrimeTime(startMinute: start, slots: slots, slotMinutes: minutes);
}

List<SerialSlot> _serials(Object? raw, PrimeTime pt, int channel) {
  if (raw == null) return const [];
  if (raw is! List) throw ConfigException('channel $channel: "serials" must be a list');
  final windowEnd = (pt.startMinute + pt.slots * pt.slotMinutes).clamp(0, 24 * 60);
  final out = <SerialSlot>[];
  for (final (i, s) in raw.indexed) {
    final what = 'channel $channel serial slot ${i + 1}';
    if (s is! Map<String, dynamic>) throw ConfigException('$what must be a JSON object');
    final start = s['start'] == null ? pt.startMinute + i * pt.slotMinutes : _clock(s['start'], '$what start');
    if (start < pt.startMinute || start + pt.slotMinutes > windowEnd) {
      throw ConfigException('$what starts outside prime time');
    }
    if (out.isNotEmpty && start < out.last.startMinute + pt.slotMinutes) {
      throw ConfigException('$what overlaps the slot before it (slots must be in time order)');
    }
    final epoch = DateTime.tryParse('${s['epoch']}');
    if (epoch == null) throw ConfigException('$what needs an "epoch" date like "2026-11-12"');
    final perDay = _int(s['perDay'], '$what perDay');
    if (perDay != null && perDay < 1) throw ConfigException('$what perDay must be 1 or more');
    final shows = s['shows'];
    if (shows is! List || shows.isEmpty) throw ConfigException('$what needs at least one show');
    out.add(SerialSlot(
      startMinute: start,
      epoch: DateTime(epoch.year, epoch.month, epoch.day),
      perDay: perDay,
      shows: [for (final sh in shows) _show(sh, what)],
    ));
  }
  return out;
}

SerialShow _show(Object? raw, String slot) {
  if (raw is! Map<String, dynamic>) throw ConfigException('$slot: each show must be a JSON object');
  final title = raw['title'];
  if (title is! String || title.trim().isEmpty) throw ConfigException('$slot: every show needs a "title"');
  final what = '$slot show "$title"';
  final ids = [for (final x in (raw['identifiers'] as List? ?? const [])) x as String];
  if (ids.isEmpty) throw ConfigException('$what needs "identifiers"');
  final order = raw['order'];
  if (order != null && order != 'natural' && order is! List) {
    throw ConfigException('$what: "order" must be "natural" or a list of file names');
  }
  final episode = _regex(raw['episode'], '$what episode');
  final groups = episode == null ? 1 : RegExp('${episode.pattern}|').firstMatch('')!.groupCount; // '|' always matches
  if (groups < 1 || groups > 2) {
    throw ConfigException('$what: "episode" needs 1 (episode) or 2 (season, episode) capture groups');
  }
  return SerialShow(
    title: title.trim(),
    identifiers: ids,
    include: _regex(raw['include'], '$what include'),
    exclude: _regex(raw['exclude'], '$what exclude'),
    episode: episode,
    order: order is List ? [for (final x in order) x as String] : null,
  );
}

RegExp? _regex(Object? raw, String what) {
  if (raw == null) return null;
  if (raw is! String) throw ConfigException('$what must be a regex string');
  try {
    return RegExp(raw, caseSensitive: false);
  } on FormatException catch (e) {
    throw ConfigException('$what is not a valid regex: ${e.message}');
  }
}

/// "HH:MM" -> minutes after midnight.
int _clock(Object? raw, String what) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch('$raw');
  final h = int.tryParse(m?.group(1) ?? '');
  final min = int.tryParse(m?.group(2) ?? '');
  if (h == null || min == null || h > 23 || min > 59) throw ConfigException('$what must be a time like "18:00"');
  return h * 60 + min;
}

YearRange? _range(Object? raw, String what) {
  if (raw == null) return null;
  if (raw is! List || raw.length != 2 || raw[0] is! int || raw[1] is! int) {
    throw ConfigException('$what must be two years, like [1980, 2010]');
  }
  final start = raw[0] as int;
  final end = raw[1] as int;
  if (start > end) {
    throw ConfigException('$what starts after it ends');
  }
  return YearRange(start, end);
}

int? _int(Object? raw, String what) {
  if (raw == null) return null;
  if (raw is! int) throw ConfigException('$what must be a whole number');
  return raw;
}

num? _num(Object? raw, String what) {
  if (raw == null) return null;
  if (raw is! num) throw ConfigException('$what must be a number');
  return raw;
}
