/// Release-name tokens that start the junk tail of a file-name title (resolution,
/// source, codec). Everything from the first one on is dropped, release group included.
final _junk = RegExp(
    r'\b(\d{3,4}p|web-?dl|web-?rip|hdtv|hdrip|blu-?ray|brrip|bdrip|dvdrip|xvid|divx|x26[45]|h\.?26[45]|hevc)\b.*$',
    caseSensitive: false);

/// A display title from a raw Archive title or file name, e.g.
/// `Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb` -> `Martha Speaks S01E39`.
/// Drops [bracketed] / {braced} tags, a video extension and the release tail;
/// dots and underscores become spaces when the title has no spaces of its own.
/// Returns [raw] trimmed if cleaning would leave nothing.
String cleanTitle(String raw) {
  var t = raw.replaceAll(RegExp(r'\[[^\]]*\]|\{[^}]*\}'), ' ');
  t = t.replaceFirst(RegExp(r'\.(mp4|m4v|mkv|avi|mov|mpe?g|ogv|webm)$', caseSensitive: false), '');
  t = t.replaceAll('_', ' ');
  if (!t.trim().contains(' ')) t = t.replaceAll('.', ' ');
  t = t.replaceFirst(_junk, '');
  t = t.replaceAll(RegExp(r'\s+'), ' ').replaceFirst(RegExp(r'[\s\-.(]+$'), '').trim();
  return t.isEmpty ? raw.trim() : t;
}
