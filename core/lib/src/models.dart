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

  Entry copyWith({bool? faststart}) => Entry(
        id: id,
        itemId: itemId,
        file: file,
        title: title,
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
