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
    final sources = <Source>[];
    if (type == 'archive') {
      final rawSources = raw['sources'];
      if (rawSources is! List || rawSources.isEmpty) {
        throw ConfigException('channel $number ($name) needs at least one source');
      }
      for (final s in rawSources) {
        sources.add(_source(s, number));
      }
    }
    channels.add(Channel(
      number: number,
      name: name.trim(),
      genre: (raw['genre'] as String?) ?? '',
      type: type,
      sources: sources,
      yearRange: _range(raw['yearRange'], 'channel $number yearRange'),
      logo: raw['logo'] as String?,
      location: raw['location'] as String?,
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
