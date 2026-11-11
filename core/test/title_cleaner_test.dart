import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

void main() {
  test('release file names become readable titles', () {
    expect(cleanTitle('Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb'), 'Martha Speaks S01E39');
    expect(cleanTitle('Farscape.S04E11.720p.BluRay.x264-DEMAND.mp4'), 'Farscape S04E11');
    expect(cleanTitle('The_Simpsons_S02E01_DVDRip_XviD'), 'The Simpsons S02E01');
    expect(cleanTitle('[Group] Cowboy Bebop - 05 [480p] {ENG}'), 'Cowboy Bebop - 05');
    expect(cleanTitle('Show.Name.S01E02.HDTV.x264'), 'Show Name S01E02');
  });

  test('ordinary titles are left alone', () {
    expect(cleanTitle('Squawk Box : CNBC : October 8, 2009'), 'Squawk Box : CNBC : October 8, 2009');
    expect(cleanTitle('Dr. Who and the Daleks (1965)'), 'Dr. Who and the Daleks (1965)');
    expect(cleanTitle("Charlotte's Web"), "Charlotte's Web");
    expect(cleanTitle('  20100601 Camp-FEMA '), '20100601 Camp-FEMA');
  });

  test('never returns empty', () {
    expect(cleanTitle('[1080p]'), '[1080p]');
  });
}
