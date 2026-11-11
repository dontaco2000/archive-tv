/// Inclusive range of years used to filter Archive items by their `date`.
class YearRange {
  final int start;
  final int end;

  const YearRange(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is YearRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'YearRange($start-$end)';
}

/// Where a channel's content comes from. Exactly one of [query],
/// [collection] or [identifiers] is set.
class Source {
  final String? query;
  final String? collection;
  final List<String> identifiers;
  final int? minDownloads;
  final bool ignoreYear;

  /// Archive mediatype: `movies` (video) or `audio`.
  final String mediatype;

  const Source({
    this.query,
    this.collection,
    this.identifiers = const [],
    this.minDownloads,
    this.ignoreYear = false,
    this.mediatype = 'movies',
  });
}

/// One channel from `channels.json`. [type] is `archive` (Archive video) or
/// `weatherstar` (the live weather web page, no sources).
class Channel {
  final int number;
  final String name;
  final String genre;
  final String type;
  final List<Source> sources;
  final YearRange? yearRange;
  final String? logo;
  final String? location;

  const Channel({
    required this.number,
    required this.name,
    this.genre = '',
    this.type = 'archive',
    this.sources = const [],
    this.yearRange,
    this.logo,
    this.location,
  });
}

/// Everything in `channels.json`.
class ChannelConfig {
  final YearRange yearRange;

  /// Earliest year a thin channel may widen back to (default 1960).
  final int fallbackStart;

  /// A channel needs at least this much playable content, in seconds.
  final int minContentSeconds;
  final List<Channel> channels;
  final Set<String> excludeIdentifiers;
  final List<String> blockCollections;

  const ChannelConfig({
    required this.yearRange,
    required this.fallbackStart,
    required this.minContentSeconds,
    required this.channels,
    this.excludeIdentifiers = const {},
    this.blockCollections = const [],
  });

  Channel? channel(int number) {
    for (final c in channels) {
      if (c.number == number) return c;
    }
    return null;
  }
}

/// One playable file: a video or audio file inside an Archive item.
class Entry {
  /// Unique id: `<itemId>/<file name>`.
  final String id;
  final String itemId;
  final String file;
  final String title;
  final double durationSeconds;
  final String url;

  /// File size in bytes, if Archive reported it.
  final int? size;

  const Entry({
    required this.id,
    required this.itemId,
    required this.file,
    required this.title,
    required this.durationSeconds,
    required this.url,
    this.size,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemId': itemId,
        'file': file,
        'title': title,
        'duration': durationSeconds,
        'url': url,
        if (size != null) 'size': size,
      };

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'] as String,
        itemId: j['itemId'] as String,
        file: j['file'] as String,
        title: j['title'] as String,
        durationSeconds: (j['duration'] as num).toDouble(),
        url: j['url'] as String,
        size: j['size'] as int?,
      );
}
