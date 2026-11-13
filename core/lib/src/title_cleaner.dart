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
String cleanTitle(String raw) {
  var t = raw.replaceAll(RegExp(r'\[[^\]]*\]|\{[^}]*\}'), ' ');
  t = t.replaceFirst(RegExp(r'\.(mp4|m4v|mkv|avi|mov|mpe?g|ogv|webm)$', caseSensitive: false), '');
  t = t.replaceAll('_', ' ');
  if (!t.trim().contains(' ')) t = t.replaceAll('.', ' ');
  t = t.replaceFirst(_junk, '');
  t = t.replaceAll(RegExp(r'(?<=[A-Za-z]{2})\.(?=\w)'), ' '); // "Block.44", "Mr.Wizard"; not "U.S.A" or "Dr. Who"
  t = t.trim().replaceFirst(_track, '').replaceFirst(_tailIds, '');
  t = t.replaceAllMapped(RegExp(r'\bS0*(\d{1,2})\b(?!\s*[-.]?\s*E\d)', caseSensitive: false), (m) => 'Season ${m[1]}');
  t = t.replaceAll(RegExp(r'\s+'), ' ').replaceFirst(RegExp(r'[\s\-.(]+$'), '').trim();
  return t.isEmpty ? raw.trim() : t;
}
