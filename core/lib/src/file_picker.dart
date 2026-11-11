import 'archive_client.dart';
import 'models.dart';

/// Turns an item's file list into playable [Entry]s: one per episode/track,
/// choosing the small, fast-to-start file for each.
///
/// Video preference per episode: the "NNNKb MPEG4" derivative closest to
/// 512 kbps, then "h.264", then plain "MPEG4", then "h.264 HD", then any .mp4.
/// "HiRes MPEG4" copies are ignored. Audio items use the MP3 files.
List<Entry> pickEntries(
  ItemMeta meta, {
  double minSeconds = 60,
  double maxSeconds = 6 * 3600,
}) {
  final audio = meta.mediatype == 'audio';
  final groups = <String, List<ArchiveFile>>{};
  final lengthByStem = <String, double>{};

  for (final f in meta.files) {
    final stem = _stem(f.name);
    if (f.length != null) lengthByStem.putIfAbsent(stem, () => f.length!);
    if (_rank(f, audio) != null) groups.putIfAbsent(stem, () => []).add(f);
  }

  final entries = <_Picked>[];
  for (final e in groups.entries) {
    final files = e.value..sort((a, b) => _rank(a, audio)!.compareTo(_rank(b, audio)!));
    final best = files.first;
    final length = best.length ?? lengthByStem[e.key];
    if (length == null || length < minSeconds || length > maxSeconds) continue;
    entries.add(_Picked(e.key, best, length));
  }

  entries.sort((a, b) => naturalCompare(a.stem, b.stem));
  final single = entries.length == 1;
  return [
    for (final p in entries)
      Entry(
        id: '${meta.identifier}/${p.file.name}',
        itemId: meta.identifier,
        file: p.file.name,
        title: p.file.title ?? (single ? (meta.title ?? _pretty(p.stem)) : _pretty(p.stem)),
        durationSeconds: p.length,
        url: downloadUrl(meta.identifier, p.file.name),
        size: p.file.size,
      ),
  ];
}

/// Direct download URL for a file (each path segment URL-encoded).
String downloadUrl(String identifier, String fileName) =>
    'https://archive.org/download/$identifier/${fileName.split('/').map(Uri.encodeComponent).join('/')}';

class _Picked {
  final String stem;
  final ArchiveFile file;
  final double length;

  _Picked(this.stem, this.file, this.length);
}

/// File name without folder-less extension and without a "_512kb" style suffix,
/// so all the encodes of one episode share a stem.
String _stem(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return base.replaceFirst(RegExp(r'_\d+kb$', caseSensitive: false), '');
}

String _pretty(String stem) => stem.split('/').last.replaceAll('_', ' ').trim();

final _kbFormat = RegExp(r'^(\d+)Kb MPEG4$');

/// Lower is better. Null means the file is not a playable candidate.
({int tier, int distance})? _rank(ArchiveFile f, bool audio) {
  final format = f.format ?? '';
  if (audio) {
    final isMp3 = format.contains('MP3') || f.name.toLowerCase().endsWith('.mp3');
    return isMp3 ? (tier: 0, distance: format == 'VBR MP3' ? 0 : 1) : null;
  }
  final kb = _kbFormat.firstMatch(format);
  if (kb != null) return (tier: 0, distance: (int.parse(kb.group(1)!) - 512).abs());
  switch (format) {
    case 'h.264':
      return (tier: 1, distance: 0);
    case 'MPEG4':
      return (tier: 2, distance: 0);
    case 'h.264 HD':
      return (tier: 3, distance: 0);
    case 'HiRes MPEG4':
      return null;
  }
  return f.name.toLowerCase().endsWith('.mp4') ? (tier: 4, distance: 0) : null;
}

extension on ({int tier, int distance}) {
  int compareTo(({int tier, int distance}) other) =>
      tier != other.tier ? tier - other.tier : distance - other.distance;
}

/// Compares strings so that "Ep 2" sorts before "Ep 10".
int naturalCompare(String a, String b) {
  final chunk = RegExp(r'(\d+|\D+)');
  final x = chunk.allMatches(a).map((m) => m.group(0)!).toList();
  final y = chunk.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final xn = int.tryParse(x[i]);
    final yn = int.tryParse(y[i]);
    final c = (xn != null && yn != null)
        ? xn.compareTo(yn)
        : x[i].toLowerCase().compareTo(y[i].toLowerCase());
    if (c != 0) return c;
  }
  return x.length - y.length;
}
