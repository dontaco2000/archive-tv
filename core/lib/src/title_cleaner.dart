/// Release-name tokens that start the junk tail of a file-name title (resolution,
/// source, codec). Everything from the first one on is dropped, release group included.
final _junk = RegExp(
    r'\b(\d{3,4}[pi]|web-?dl|web-?rip|hdtv|hdrip|blu-?ray|brrip|bdrip|dvdrip|tvrip|vhsrip|satrip|pdtv|xvid|divx|x26[45]|h\.?26[45]|hevc|aac2?|ac3|dd5)\b.*$',
    caseSensitive: false);

/// "05. Blue's Clues", "12 - Title", "3) Title": a track number in front (not "101 Dalmatians", "2001: ...").
final _track = RegExp(r'^\d{1,3}\s*[.)\-]\s+(?=\D)');

/// Trailing tape/catalogue ids ("EC#73 EC#181") and bitrate tags ("_512kb").
final _tailIds = RegExp(r'(\s+[A-Za-z]{1,4}#\d+|\s+\d+kb)+$', caseSensitive: false);

/// A display title from a raw Archive title or file name, e.g.
/// `Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb` -> `Martha Speaks S01E39`.
/// Drops [bracketed] / {braced} tags, a video extension, the release tail, a leading track number
/// and trailing ids; dots and underscores become spaces ("Noggin.Block.44" -> "Noggin Block 44"),
/// a lone season tag becomes "Season N" ("Cops S10" -> "Cops Season 10").
/// Returns [raw] trimmed if cleaning would leave nothing.
// Compiled once: building these per call was most of cleanTitle's cost (On Demand cleans ~30k titles at a time).
final _tags = RegExp(r'\[[^\]]*\]|\{[^}]*\}');
final _ext = RegExp(r'\.(mp4|m4v|mkv|avi|mov|mpe?g|ogv|webm)$', caseSensitive: false);
final _firstWord = RegExp(r'^\S+[\s\-:]*');
final _innerDot = RegExp(r'(?<=[A-Za-z]{2})\.(?=\w)');
final _loneSeason = RegExp(r'\bS0*(\d{1,2})\b(?!\s*[-.]?\s*E\d)', caseSensitive: false);
final _spaces = RegExp(r'\s+');

String cleanTitle(String raw) {
  var t = raw.replaceAll(_tags, ' ');
  t = t.replaceFirst(_ext, '');
  t = t.replaceAll('_', ' ');
  if (!t.trim().contains(' ')) t = t.replaceAll('.', ' ');
  t = t.trim().replaceFirst(_track, '');
  // the release tail; a release tag in front ("BluRay - An Idiot Abroad") loses just the tag
  final junk = _junk.firstMatch(t);
  if (junk != null) t = junk.start == 0 ? t.replaceFirst(_firstWord, '') : t.substring(0, junk.start);
  if (t.contains('.')) t = t.replaceAll(_innerDot, ' '); // "Block.44", "Mr.Wizard"; not "U.S.A" or "Dr. Who"
  // (the guards skip regexes that cannot match: these two backtrack at every space)
  if (t.contains('#') || t.toLowerCase().endsWith('kb')) t = t.replaceFirst(_tailIds, '');
  t = t.replaceAllMapped(_loneSeason, (m) => 'Season ${m[1]}');
  t = t.replaceAll(_spaces, ' ');
  var end = t.length;
  while (end > 0 && ' -.('.contains(t[end - 1])) {
    end--;
  }
  t = t.substring(0, end).trim();
  return t.isEmpty ? raw.trim() : t;
}
