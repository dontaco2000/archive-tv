import 'package:archive_tv_player/player/picture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const full = CropRect(0, 0, 640, 360);
  // A 4:3 picture boxed inside a 16:9 frame with bars on all four sides (the Ringside case).
  const boxed = CropRect(144, 24, 352, 312);
  List<CropRect?> times(CropRect? r, int n) => List.filled(n, r);

  test('parses mpv vf-metadata JSON, ignoring x1/x2/y1/y2; empty or negative boxes are no reading', () {
    const meta = '{"lavfi.cropdetect.x1":"144","lavfi.cropdetect.x2":"495","lavfi.cropdetect.y1":"24",'
        '"lavfi.cropdetect.y2":"335","lavfi.cropdetect.w":"352","lavfi.cropdetect.h":"312",'
        '"lavfi.cropdetect.x":"144","lavfi.cropdetect.y":"24"}';
    expect(parseCropdetect(meta), boxed);
    expect(parseCropdetect(''), isNull);
    expect(parseCropdetect('{"lavfi.cropdetect.w":"-638","lavfi.cropdetect.h":"-358","lavfi.cropdetect.x":"0","lavfi.cropdetect.y":"0"}'),
        isNull);
  });

  test('undecided until enough samples and the last ones agree', () {
    expect(decideCrop(times(boxed, 5), 640, 360), isNull);
    expect(decideCrop([...times(boxed, 3), null, ...times(boxed, 3)], 640, 360), isNull);
    expect(decideCrop([...times(boxed, 4), const CropRect(140, 24, 360, 312), boxed], 640, 360), isNull);
    expect(decideCrop(times(boxed, 6), 640, 360), boxed);
    expect(decideCrop([null, null, ...times(boxed, 4)], 640, 360), boxed);
  });

  test('clean video (no or tiny borders) is left alone', () {
    expect(decideCrop(times(full, 6), 640, 360), full);
    // 2% bars left/right and 3% top/bottom: under the 6% threshold on both axes.
    expect(decideCrop(times(const CropRect(6, 6, 628, 348), 6), 640, 360), full);
  });

  test('only the axis with real bars is cropped', () {
    // Letterboxed 4:3 file: bars top and bottom only (plus a few noisy columns).
    expect(decideCrop(times(const CropRect(4, 60, 632, 360), 6), 640, 480), const CropRect(0, 60, 640, 360));
  });

  test('off-centre boxes (a dark scene with one bright spot) are not cropped', () {
    expect(decideCrop(times(const CropRect(20, 24, 352, 312), 6), 640, 360), const CropRect(0, 24, 640, 312));
    expect(decideCrop(times(const CropRect(20, 0, 300, 100), 6), 640, 360), full);
  });

  test('a box keeping under a third of a dimension is refused; boxes outside the frame mean no crop', () {
    expect(decideCrop(times(const CropRect(260, 0, 120, 360), 6), 640, 360), full);
    expect(decideCrop(times(const CropRect(0, 0, 720, 480), 6), 640, 360), full);
  });

  test('crop offsets and sizes are even', () {
    final r = decideCrop(times(const CropRect(145, 25, 351, 311), 6), 640, 360)!;
    expect([r.x, r.y, r.w, r.h].every((v) => v.isEven), isTrue);
    expect(r, const CropRect(144, 24, 350, 310));
  });

  test('after the first decision only a materially wider box replaces the crop', () {
    expect(cropShouldChange(null, boxed, 640, 360), isTrue);
    expect(cropShouldChange(null, full, 640, 360), isTrue);
    expect(cropShouldChange(boxed, boxed, 640, 360), isFalse);
    expect(cropShouldChange(boxed, const CropRect(150, 30, 340, 300), 640, 360), isFalse); // smaller: never
    expect(cropShouldChange(boxed, const CropRect(142, 24, 356, 312), 640, 360), isFalse); // 4 px: noise
    expect(cropShouldChange(boxed, const CropRect(100, 24, 440, 312), 640, 360), isTrue);
    expect(cropShouldChange(boxed, full, 640, 360), isTrue); // the borders turned out to be picture
  });
}
