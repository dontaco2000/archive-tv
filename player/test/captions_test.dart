import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/player/captions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Entry entry({String? language, String? subUrl}) => Entry(
    id: 'i/f.mp4', itemId: 'i', file: 'f.mp4', title: 't', durationSeconds: 600, url: 'u', language: language, subUrl: subUrl);

void main() {
  late List<List<String>> calls;
  Future<void> rec(List<String> a) async => calls.add(a);
  setUp(() => calls = []);

  const embeddedEn = SubTrack(3, lang: 'eng');
  const embeddedFr = SubTrack(4, lang: 'fre');
  const untagged = SubTrack(5);

  test('every open starts with automatic subtitles off (the Caillou fix)', () async {
    await resetCaptions(rec);
    expect(calls, [
      ['set', 'sub-auto', 'no'],
      ['set', 'sid', 'no'],
    ]);
  });

  test('English item, CC off: no captions even when the file has a default track', () async {
    expect(await applyCaptions(rec, entry(), [embeddedEn, untagged], captionsOn: false), 'off');
    expect(calls, [
      ['set', 'sid', 'no'],
    ]);
  });

  test('English item, CC on: embedded track first (untagged counts), else the sidecar, else none', () async {
    expect(await applyCaptions(rec, entry(subUrl: 's.srt'), [untagged], captionsOn: true), 'on');
    expect(calls.last, ['set', 'sid', '5']);
    expect(await applyCaptions(rec, entry(subUrl: 's.srt'), const [], captionsOn: true), 'on');
    expect(calls.last, ['sub-add', 's.srt', 'select', 'English', 'en']);
    calls.clear();
    expect(await applyCaptions(rec, entry(), [embeddedFr], captionsOn: true), 'none');
    expect(calls, isEmpty);
  });

  test('foreign item: forced on whatever CC says; sidecar first, then an embedded English track', () async {
    expect(await applyCaptions(rec, entry(language: 'fre', subUrl: 's.srt'), [embeddedEn], captionsOn: false), 'forced');
    expect(calls.last, ['sub-add', 's.srt', 'select', 'English', 'en']);
    // Already added (CC toggled): select it again instead of adding a second copy.
    expect(
        await applyCaptions(rec, entry(language: 'fre', subUrl: 's.srt'),
            [embeddedEn, const SubTrack(7, lang: 'en', external: true)], captionsOn: false),
        'forced');
    expect(calls.last, ['set', 'sid', '7']);
    expect(await applyCaptions(rec, entry(language: 'jpn'), [embeddedFr, embeddedEn], captionsOn: false), 'forced');
    expect(calls.last, ['set', 'sid', '3']);
  });

  test('foreign item without English subtitles is "missing" (untagged tracks do not count)', () async {
    expect(await applyCaptions(rec, entry(language: 'jpn'), [embeddedFr, untagged], captionsOn: true), 'missing');
    expect(calls, isEmpty);
  });

  test('weather music (not an Archive video channel) is never forced', () async {
    expect(await applyCaptions(rec, entry(language: 'fre'), const [], captionsOn: false, forceForeign: false), 'off');
  });

  test('track-list JSON: subtitle tracks only; junk gives none', () {
    final t = parseSubTracks('[{"id":1,"type":"video"},{"id":1,"type":"audio","lang":"eng"},'
        '{"id":2,"type":"sub","lang":"eng","title":"English SDH"},{"id":3,"type":"sub","external":true}]');
    expect(t.map((s) => (s.id, s.lang, s.external)), [(2, 'eng', false), (3, null, true)]);
    expect(parseSubTracks('nope'), isEmpty);
    expect(isEnglishTrack(const SubTrack(1, title: 'English')), isTrue);
    expect(isEnglishTrack(const SubTrack(1, lang: 'en-US')), isTrue);
    expect(isEnglishTrack(untagged), isFalse);
    expect(isEnglishTrack(untagged, lenient: true), isTrue);
  });

  test('caption style: larger than media_kit default, grows with the size step, white on dark', () {
    final def = captionStyle(720, captionSizeDefault);
    // media_kit's own default in a 960x720 frame: 32 px * sqrt(960*720 / (1920*1080)) = about 18.5 px.
    expect(def.style.fontSize!, greaterThan(18.5 * 2));
    expect(def.textScaler, TextScaler.noScaling);
    expect(def.style.color, Colors.white);
    expect(def.style.shadows, isNotEmpty);
    expect(def.padding.bottom, greaterThan(0));
    final sizes = [for (var s = 1; s <= 7; s++) captionStyle(720, s).style.fontSize!];
    expect(sizes, [...sizes]..sort());
    expect(sizes.toSet(), hasLength(7));
    expect(captionStyle(720, 99).style.fontSize, sizes.last);
    expect(captionStyle(720, 4, visible: false).visible, isFalse);
  });
}
