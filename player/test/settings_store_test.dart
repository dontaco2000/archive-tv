import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('settings_test');
    file = File('${dir.path}/settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('round-trip', () {
    final s = Settings()
      ..favorites = {3, 7}
      ..volume = 42
      ..muted = true
      ..startFullscreen = true
      ..cornerBug = false
      ..favoritesOnly = true
      ..windowX = 10
      ..windowY = 20
      ..windowW = 800
      ..windowH = 600
      ..fullscreen = true
      ..lastChannel = 21;
    SettingsStore(file).save(s);
    final r = SettingsStore(file).load();
    expect(r.favorites, {3, 7});
    expect(r.volume, 42);
    expect(r.muted, false); // mute is never restored: the app always starts with sound
    expect(r.startFullscreen, true);
    expect(r.cornerBug, false);
    expect(r.favoritesOnly, true);
    expect([r.windowX, r.windowY, r.windowW, r.windowH], [10, 20, 800, 600]);
    expect(r.fullscreen, true);
    expect(r.lastChannel, 21);
  });

  test('missing file gives defaults', () {
    final s = SettingsStore(file).load();
    expect(s.volume, 80);
    expect(s.favorites, isEmpty);
    expect(s.windowW, isNull);
    expect(s.cornerBug, false);
  });

  test('corrupt JSON gives defaults', () {
    file.writeAsStringSync('{not json');
    expect(SettingsStore(file).load().volume, 80);
  });

  test('wrong types fall back, unknown keys ignored', () {
    file.writeAsStringSync(jsonEncode({
      'volume': 'loud',
      'muted': 'yes',
      'favorites': ['a', 5],
      'windowX': 'left',
      'bogus': 1,
    }));
    final s = SettingsStore(file).load();
    expect(s.volume, 80);
    expect(s.muted, false);
    expect(s.favorites, {5});
    expect(s.windowX, isNull);
  });

  test('toggleFavorite adds then removes', () {
    final s = Settings();
    expect(toggleFavorite(s, 5), true);
    expect(s.favorites, {5});
    expect(toggleFavorite(s, 5), false);
    expect(s.favorites, isEmpty);
  });

  test('save leaves no tmp file', () {
    SettingsStore(file).save(Settings());
    expect(file.existsSync(), true);
    expect(dir.listSync().map((e) => e.path).where((p) => p.endsWith('.tmp')),
        isEmpty);
  });

  test('volume leveling: default normal (also for old files), round-trip, bad value ignored, cycle, filters', () {
    expect(Settings().volumeLeveling, 'normal');
    file.writeAsStringSync(jsonEncode({'volume': 50})); // settings.json from before 0.5
    final old = SettingsStore(file).load();
    expect(old.volumeLeveling, 'normal');
    expect(old.noticeAccepted, isFalse);
    SettingsStore(file).save(old
      ..volumeLeveling = 'strong'
      ..noticeAccepted = true);
    final back = SettingsStore(file).load();
    expect(back.volumeLeveling, 'strong');
    expect(back.noticeAccepted, isTrue);
    expect(Settings.fromJson({'volumeLeveling': 'max'}).volumeLeveling, 'normal');

    expect(cycleLeveling('off', 1), 'normal');
    expect(cycleLeveling('normal', 1), 'strong');
    expect(cycleLeveling('strong', 1), 'off');
    expect(cycleLeveling('off', -1), 'strong');
    expect(cycleLeveling('bogus', 1), 'strong');

    expect(levelingFilter('off'), '');
    expect(levelingFilter('normal'), 'dynaudnorm=f=250:g=15:p=0.9:m=10:r=0.15');
    expect(levelingFilter('strong'), allOf(startsWith('dynaudnorm='), contains(',acompressor='), endsWith(',alimiter=limit=0.95')));
  });

  test('a saved mute (old settings.json) is ignored at startup; the volume level is kept', () {
    file.writeAsStringSync(jsonEncode({'volume': 100, 'muted': true}));
    final s = SettingsStore(file).load();
    expect(s.muted, isFalse);
    expect(s.volume, 100);
    SettingsStore(file).save(s..muted = true);
    expect(jsonDecode(file.readAsStringSync()), isNot(contains('muted')));
    expect(Settings.fromJson({'volume': 0}).volume, 0); // volume 0 stays 0
  });

  test('captions: off and size 4 by default (also for old files), round-trip, size clamped, bad types ignored', () {
    expect((Settings().captionsOn, Settings().captionSize), (false, 4));
    file.writeAsStringSync(jsonEncode({'volume': 50}));
    final old = SettingsStore(file).load();
    expect((old.captionsOn, old.captionSize), (false, 4));
    SettingsStore(file).save(Settings()
      ..captionsOn = true
      ..captionSize = 6);
    final back = SettingsStore(file).load();
    expect((back.captionsOn, back.captionSize), (true, 6));
    expect(Settings.fromJson({'captionSize': 12}).captionSize, 7);
    expect(Settings.fromJson({'captionSize': '5'}).captionSize, 4);
    expect(Settings.fromJson({'captionsOn': 'yes'}).captionsOn, isFalse);
  });
}
