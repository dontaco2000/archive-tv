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
      ..fullscreen = true;
    SettingsStore(file).save(s);
    final r = SettingsStore(file).load();
    expect(r.favorites, {3, 7});
    expect(r.volume, 42);
    expect(r.muted, true);
    expect(r.startFullscreen, true);
    expect(r.cornerBug, false);
    expect(r.favoritesOnly, true);
    expect([r.windowX, r.windowY, r.windowW, r.windowH], [10, 20, 800, 600]);
    expect(r.fullscreen, true);
  });

  test('missing file gives defaults', () {
    final s = SettingsStore(file).load();
    expect(s.volume, 80);
    expect(s.favorites, isEmpty);
    expect(s.windowW, isNull);
    expect(s.cornerBug, true);
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
}
