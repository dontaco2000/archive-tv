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

  /// At most this many entries (episodes/files) from this source, spread evenly over its items, so one huge
  /// season pack or race archive can't swamp the channel. Null = no cap.
  final int? maxEntries;

  /// At most this many entries from any ONE item of this source (spread evenly over the item's files), so a single
  /// 100+ file concert or series pack can't dominate a source even when the source has few other items. Applied
  /// before [maxEntries]. Null = no cap.
  final int? maxEntriesPerItem;

  /// Archive mediatype: `movies` (video) or `audio`.
  final String mediatype;

  const Source({
    this.query,
    this.collection,
    this.identifiers = const [],
    this.minDownloads,
    this.ignoreYear = false,
    this.maxEntries,
    this.maxEntriesPerItem,
    this.mediatype = 'movies',
  });
}

/// One channel from `channels.json`. [type] is `archive` (Archive video) or
/// `weatherstar` (the weather screens; its optional [sources] are background music).
class Channel {
  final int number;
  final String name;
  final String genre;
  final String type;
  final List<Source> sources;
  final YearRange? yearRange;
  final String? logo;
  final String? location;

  /// The evening window the [serials] sit in.
  final PrimeTime primeTime;

  /// Serial blocks, in time order (empty: the whole day is the normal shuffle).
  final List<SerialSlot> serials;

  /// Guide label for a channel made of short spots (e.g. "Commercials"): the guide shows its
  /// schedule as 2-hour "More <label>" blocks instead of single items. Null = normal grouping.
  final String? shortContent;

  const Channel({
    required this.number,
    required this.name,
    this.genre = '',
    this.type = 'archive',
    this.sources = const [],
    this.yearRange,
    this.logo,
    this.location,
    this.primeTime = const PrimeTime(),
    this.serials = const [],
    this.shortContent,
  });
}

/// The prime-time window: [slots] blocks of [slotMinutes] from [startMinute] (minutes after local midnight).
class PrimeTime {
  final int startMinute;
  final int slots;
  final int slotMinutes;

  const PrimeTime({this.startMinute = 18 * 60, this.slots = 6, this.slotMinutes = 60});
}

/// One prime-time block: a queue of [shows] played in episode order, back to back, looping.
/// The episode index on a day is `((day - epoch) * perDay) mod (episodes in the whole queue)`.
class SerialSlot {
  final int startMinute;
  final DateTime epoch;

  /// Episodes per day; null = as many as fit the slot by median episode length (at least 1).
  final int? perDay;
  final List<SerialShow> shows;

  const SerialSlot({required this.startMinute, required this.epoch, this.perDay, required this.shows});
}

/// One show in a [SerialSlot] queue and how to find its episodes in its Archive items.
/// Order: [episode] regex (1 group = episode, 2 = season and episode), else the explicit
/// file-name [order], else natural file-name order. [include]/[exclude] filter file names.
class SerialShow {
  final String title;
  final List<String> identifiers;
  final RegExp? include;
  final RegExp? exclude;
  final RegExp? episode;
  final List<String>? order;

  const SerialShow({
    required this.title,
    required this.identifiers,
    this.include,
    this.exclude,
    this.episode,
    this.order,
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

  /// Whether the mp4 index is at the front (see `probeFaststart`); null = not probed.
  final bool? faststart;

  /// The Archive item's `language` metadata as given (null = not tagged). See [foreign].
  final String? language;

  /// Download URL of an English sidecar subtitle file (.srt/.vtt/...) for this file, if the item has one.
  final String? subUrl;

  /// The item is tagged as a silent film (`sound: silent`).
  final bool silent;

  const Entry({
    required this.id,
    required this.itemId,
    required this.file,
    required this.title,
    required this.durationSeconds,
    required this.url,
    this.size,
    this.faststart,
    this.language,
    this.subUrl,
    this.silent = false,
  });

  /// Tagged with a language and none of its languages is English: needs English subtitles.
  bool get foreign => isForeignLanguage(language);

  Entry copyWith({bool? faststart, String? title}) => Entry(
        id: id,
        itemId: itemId,
        file: file,
        title: title ?? this.title,
        durationSeconds: durationSeconds,
        url: url,
        size: size,
        faststart: faststart ?? this.faststart,
        language: language,
        subUrl: subUrl,
        silent: silent,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'itemId': itemId,
        'file': file,
        'title': title,
        'duration': durationSeconds,
        'url': url,
        if (size != null) 'size': size,
        if (faststart != null) 'faststart': faststart,
        if (language != null) 'language': language,
        if (subUrl != null) 'subUrl': subUrl,
        if (silent) 'silent': true,
      };

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        id: j['id'] as String,
        itemId: j['itemId'] as String,
        file: j['file'] as String,
        title: j['title'] as String,
        durationSeconds: (j['duration'] as num).toDouble(),
        url: j['url'] as String,
        size: j['size'] as int?,
        faststart: j['faststart'] as bool?,
        language: j['language'] as String?,
        subUrl: j['subUrl'] as String?,
        silent: j['silent'] == true,
      );
}

/// Language values that say nothing about spoken language (no dialogue, unknown, several).
const _neutralLanguages = {'zxx', 'und', 'mul', 'mis', 'none', 'n/a', 'no linguistic content', 'silent', 'no dialogue', 'music', 'international', 'multiple', 'multi'};

/// True when Archive's `language` value names a language and none of the named ones is English
/// ("fre", "Japanese", "spa; fre"). Untagged, English ("eng", "en-US", "English, French") and
/// neutral values ("zxx", "und") are not foreign.
bool isForeignLanguage(String? language) {
  if (language == null) return false;
  final parts = [
    for (final p in language.toLowerCase().split(RegExp(r'[,;/|]|\band\b')))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  if (parts.isEmpty || parts.every(_neutralLanguages.contains)) return false;
  return !parts.any((p) => p == 'en' || p == 'eng' || p.startsWith('en-') || p.startsWith('en_') || p.contains('english'));
}
