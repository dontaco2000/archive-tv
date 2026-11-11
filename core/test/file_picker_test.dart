import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/src/archive_client.dart';
import 'package:archive_tv_core/src/file_picker.dart';
import 'package:test/test.dart';

ItemMeta loadMeta(String fixtureName) {
  final json = jsonDecode(File('test/fixtures/$fixtureName').readAsStringSync()) as Map<String, dynamic>;
  final meta = json['metadata'] as Map<String, dynamic>;
  return ItemMeta(
    meta['identifier'] as String,
    title: meta['title'] as String?,
    mediatype: meta['mediatype'] as String,
    files: [
      for (final f in (json['files'] as List).cast<Map<String, dynamic>>())
        ArchiveFile(
          f['name'] as String,
          format: f['format'] as String?,
          size: int.tryParse('${f['size']}'),
          length: parseLength(f['length']),
          title: f['title'] as String?,
        ),
    ],
  );
}

void main() {
  test('real single-file item: picks the 512Kb file and ignores HiRes copies', () {
    final entries = pickEntries(loadMeta('meta_single.json'));
    expect(entries, hasLength(1));
    final e = entries.single;
    expect(e.file, 'comdex_2_512kb.mp4');
    expect(e.id, 'comdex_2/comdex_2_512kb.mp4');
    expect(e.title, 'Comdex 1987'); // single file: the item title
    expect(e.durationSeconds, closeTo(1763.26, 0.001));
    expect(e.size, 128125571);
    expect(e.url, 'https://archive.org/download/comdex_2/comdex_2_512kb.mp4');
  });

  test('multi-episode item: one entry per episode, natural order, short extras skipped', () {
    final entries = pickEntries(loadMeta('meta_series.json'));
    expect(entries.map((e) => e.title), [
      'Toon Series - S01E01',
      'Toon Series - S01E02',
      'Toon Series - S01E10',
    ]);
    // E01 has a 512kb and an h.264 copy: the 512kb one wins.
    expect(entries[0].file, 'Toon Series - S01E01_512kb.mp4');
    expect(entries[1].file, 'Toon Series - S01E02.mp4');
    // "00:22:05" style length on the original is used when the mp4 has its own.
    expect(entries[0].durationSeconds, 1325);
    // Spaces are encoded in the URL.
    expect(entries[1].url,
        'https://archive.org/download/toon-series-1/Toon%20Series%20-%20S01E02.mp4');
  });

  test('audio item: MP3 tracks, titles and clock-format lengths', () {
    final entries = pickEntries(loadMeta('meta_audio.json'));
    expect(entries.map((e) => e.file), ['01 Intro.mp3', '02 Night Drive.mp3']);
    expect(entries[0].title, 'Intro Groove');
    expect(entries[1].durationSeconds, 285);
  });

  test('length limits', () {
    final meta = ItemMeta('x', files: const [
      ArchiveFile('a.mp4', format: 'h.264', length: 30),
      ArchiveFile('b.mp4', format: 'h.264', length: 100),
      ArchiveFile('c.mp4', format: 'h.264', length: 30000),
      ArchiveFile('d.mp4', format: 'h.264'),
    ]);
    expect(pickEntries(meta).map((e) => e.file), ['b.mp4']);
    expect(pickEntries(meta, minSeconds: 10, maxSeconds: 50).map((e) => e.file), ['a.mp4']);
  });

  test('naturalCompare orders numbers by value', () {
    final names = ['Ep 10', 'Ep 2', 'ep 1', 'Ep 2b'];
    names.sort(naturalCompare);
    expect(names, ['ep 1', 'Ep 2', 'Ep 2b', 'Ep 10']);
  });
}
