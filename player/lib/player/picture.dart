/// Picture setting: 'auto' crops black borders baked into the file, 'fill' also scales the picture to cover
/// the frame, 'off' plays the file untouched. See _build/picture-report.md.
const pictureModes = ['auto', 'fill', 'off'];

/// The picture mode [dir] steps (+1/-1, wrapping) from [current].
String cyclePicture(String current, int dir) {
  final i = pictureModes.indexOf(current);
  return pictureModes[((i < 0 ? 0 : i) + dir) % pictureModes.length];
}

/// mpv vf entry that measures the borders. reset=0: the box is the union of every frame since the filter
/// started, so it only ever grows (a dark scene can't shrink it). limit 24 of 255 = near pure black.
const cropdetectFilter = '@atv_cd:cropdetect=limit=24:round=2:reset=0';

class CropRect {
  final int x, y, w, h;
  const CropRect(this.x, this.y, this.w, this.h);

  @override
  bool operator ==(Object other) => other is CropRect && other.x == x && other.y == y && other.w == w && other.h == h;
  @override
  int get hashCode => Object.hash(x, y, w, h);
  @override
  String toString() => '${w}x$h+$x+$y';
}

/// Reads lavfi.cropdetect.x/y/w/h from mpv's `vf-metadata/<label>` text (JSON); null if absent or empty.
CropRect? parseCropdetect(String meta) {
  final v = <String, int>{};
  for (final m in RegExp(r'lavfi\.cropdetect\.([xywh])\b[":=\s]*(-?\d+)').allMatches(meta)) {
    v[m[1]!] = int.parse(m[2]!);
  }
  final x = v['x'], y = v['y'], w = v['w'], h = v['h'];
  if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0 || x < 0 || y < 0) return null;
  return CropRect(x, y, w, h);
}

/// Decides the crop from cropdetect [samples] (oldest first, one per second; null = no reading) on a
/// [srcW]x[srcH] video. Returns null while undecided, the full frame for "leave it alone", else the crop.
///
/// Conservative: the last [stable] samples must be identical; an axis is only cropped when its bars add
/// up to at least [minBorder] of that dimension and are centred (baked-in bars are symmetric; an off-centre
/// box is a dark scene); a crop that would keep less than [minKeep] of a dimension is refused.
CropRect? decideCrop(List<CropRect?> samples, int srcW, int srcH,
    {int minSamples = 6, int stable = 4, double minBorder = 0.06, double minKeep = 0.34}) {
  final full = CropRect(0, 0, srcW, srcH);
  if (srcW <= 0 || srcH <= 0 || samples.length < minSamples) return null;
  final last = samples.sublist(samples.length - stable);
  final r = last.first;
  if (r == null || last.any((s) => s != r)) return null;
  if (r.x + r.w > srcW || r.y + r.h > srcH) return full; // not this video's numbers

  // One axis: (offset, size) to keep, or the whole axis if its bars are too small or lopsided.
  (int, int) axis(int off, int size, int src) {
    final before = off, after = src - off - size;
    if (before + after < minBorder * src) return (0, src);
    if ((before - after).abs() > 0.02 * src + 4) return (0, src);
    if (size < minKeep * src) return (0, src);
    return (off & ~1, size & ~1); // even offset and size
  }

  final (x, w) = axis(r.x, r.w, srcW);
  final (y, h) = axis(r.y, r.h, srcH);
  return CropRect(x, y, w, h);
}

/// Whether [next] should replace the crop on screen ([current], null = none). The first decision always
/// applies; after that only a materially wider box does (cropdetect's box only grows; a smaller one after
/// a filter restart must not cut picture that was already shown).
bool cropShouldChange(CropRect? current, CropRect next, int srcW, int srcH) {
  if (current == null) return true;
  if (next == current || next.w < current.w || next.h < current.h) return false;
  return next.w - current.w >= 0.02 * srcW || next.h - current.h >= 0.02 * srcH;
}
