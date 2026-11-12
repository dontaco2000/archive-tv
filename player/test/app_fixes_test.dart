import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/engine/tv_engine.dart';
import 'package:archive_tv_player/input/actions.dart';
import 'package:archive_tv_player/player/picture.dart';
import 'package:archive_tv_player/remote/remote_page.dart';
import 'package:archive_tv_player/remote/remote_server.dart';
import 'package:archive_tv_player/settings/crash_log.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/about_overlay.dart';
import 'package:archive_tv_player/ui/credits_overlay.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:archive_tv_player/ui/tv_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('app_fixes_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('STAND BY dots cycle . .. ... at a fixed width; messages show as is', () {
    expect([for (var i = 0; i < 4; i++) standByText(null, i)], ['STAND BY.  ', 'STAND BY.. ', 'STAND BY...', 'STAND BY.  ']);
    expect(standByText('NO SIGNAL', 1), 'NO SIGNAL');
  });

  testWidgets('STAND BY card: logo twice the old 140 px, dots animate, fits a small window', (t) async {
    t.view.physicalSize = const Size(1024, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: StandByCard(channel: Channel(number: 13, name: 'Drive-In')))));
    expect(t.getSize(find.byType(Image)).height, 280);
    expect(find.text('STAND BY.  '), findsOneWidget);
    await t.pump(const Duration(milliseconds: 460));
    expect(find.text('STAND BY.. '), findsOneWidget);
    t.view.physicalSize = const Size(320, 240);
    await t.pump();
    expect(t.takeException(), isNull); // scaled down, no overflow
    await t.pumpWidget(const SizedBox()); // stops the timer
  });

  testWidgets('build-mode notice: two centred lines, logo keeps its size', (t) async {
    t.view.physicalSize = const Size(1024, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: StandByCard(channel: Channel(number: 10, name: 'Teaser'), message: buildingMessage))));
    expect(find.text(buildingMessage), findsOneWidget);
    expect(t.getSize(find.byType(Image)).height, 280); // not scaled down at full size
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  test('Picture decodes with copy-back only while detecting', () {
    expect(pictureHwdec(detecting: true), 'auto-copy');
    expect(pictureHwdec(detecting: false), 'auto');
  });

  group('A/V sync nudge', () {
    test('steps, clamps, resets, and keeps only non-zero delays', () {
      final s = Settings();
      expect(nudgeAudioDelay(s, 'rosie', audioDelayStepMs), 50);
      expect(nudgeAudioDelay(s, 'rosie', audioDelayStepMs), 100);
      expect(nudgeAudioDelay(s, 'other', -audioDelayStepMs), -50);
      expect(s.audioDelays, {'rosie': 100, 'other': -50});
      expect(nudgeAudioDelay(s, 'other', audioDelayStepMs), 0);
      expect(s.audioDelays, {'rosie': 100});
      for (var i = 0; i < 100; i++) {
        nudgeAudioDelay(s, 'rosie', audioDelayStepMs);
      }
      expect(s.audioDelays['rosie'], maxAudioDelayMs);
      expect(nudgeAudioDelay(s, 'rosie', 0), 0);
      expect(s.audioDelays, isEmpty);
    });

    test('saved per item and loaded back; junk entries dropped', () {
      final f = File('${dir.path}/settings.json');
      final s = Settings();
      nudgeAudioDelay(s, 'OakleyTapes-rosie-1', -150);
      SettingsStore(f).save(s);
      expect(SettingsStore(f).load().audioDelays, {'OakleyTapes-rosie-1': -150});
      f.writeAsStringSync('{"audioDelays":{"a":200,"b":"x","c":0,"d":99999}}');
      expect(SettingsStore(f).load().audioDelays, {'a': 200, 'd': maxAudioDelayMs});
    });

    test('keys [, ], backslash and remote buttons', () {
      expect(keyboardBindings[LogicalKeyboardKey.bracketLeft]!.action, TvAction.audioEarlier);
      expect(keyboardBindings[LogicalKeyboardKey.bracketRight]!.action, TvAction.audioLater);
      expect(keyboardBindings[LogicalKeyboardKey.backslash]!.action, TvAction.audioReset);
      expect(remoteKeys['audioEarlier'], LogicalKeyboardKey.bracketLeft);
      expect(remoteKeys['audioReset'], LogicalKeyboardKey.backslash);
      expect(remotePage, contains('data-key="audioLater"'));
      expect(remotePage, contains('id="avDelay"'));
    });
  });

  group('crash log', () {
    test('a clean run leaves no marker; an unclean one is reported with the log tail kept', () {
      final logFile = File('${dir.path}/archive_tv.log')..writeAsStringSync('old line\n' * 3);
      final lines = <String>[];
      var c = CrashLog(dir, lines.add);
      expect(c.start(logFile), false);
      c.running(false); // clean exit
      expect(CrashLog(dir, lines.add).start(logFile), false);
      // ...this run never cleared its marker (crash):
      c = CrashLog(dir, lines.add);
      expect(c.start(logFile, tailBytes: 9), true);
      expect(lines.single, contains('previous run ended unexpectedly'));
      expect(c.tailFile.readAsStringSync(), 'old line\n');
    });

    test('uncaught errors are logged with their stack and kept as the last error', () {
      final lines = <String>[];
      final c = CrashLog(dir, lines.add);
      expect(c.lastError, isNull);
      expect(lastErrorLabel(c.lastError), 'Last error: none');
      c.error('zone', StateError('boom'), StackTrace.fromString('#0 main (main.dart:1)'));
      expect(lines.single, contains('uncaught (zone): Bad state: boom'));
      expect(lines.single, contains('#0 main'));
      expect(c.lastError, contains('#0 main'));
      expect(lastErrorLabel(c.lastError), 'Last error (Enter: copy): uncaught (zone): Bad state: boom');
    });
  });

  group('credits', () {
    test('lists every required credit with a link, and the content disclaimer', () {
      final text = credits.map((c) => '${c.name} ${c.url}').join('\n');
      for (final s in ['archive.org', 'Matt Walsh', 'weatherstar.netbymatt.com', 'open-meteo.com', 'weather.gov', 'mpv.io', 'Flutter', 'WebView2']) {
        expect(text, contains(s));
      }
      expect(credits.first.what, contains('Not affiliated'));
      expect(creditsDisclaimer, contains('not responsible'));
      expect(creditsDisclaimer, contains('mature'));
      // Same wording in the README snippet.
      final md = File('../../_build/credits-text.md');
      if (md.existsSync()) {
        final t = md.readAsStringSync();
        for (final c in credits) {
          expect(t, contains(c.what), reason: c.name);
        }
        expect(t, contains(creditsDisclaimer));
      }
    });

    testWidgets('credits overlay fits 4:3 windows; Up/Down select, Esc closes', (t) async {
      for (final size in const [Size(1920, 1440), Size(1024, 768), Size(800, 600), Size(640, 480)]) {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final closed = <bool>[];
        await t.pumpWidget(MaterialApp(home: Scaffold(body: CreditsOverlay(onClose: () => closed.add(true), log: (_) {}))));
        await t.pump();
        expect(find.text('CREDITS'), findsOneWidget);
        expect(t.takeException(), isNull); // no overflow
        await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await t.sendKeyEvent(LogicalKeyboardKey.escape);
        expect(closed, [true]);
      }
    });

    testWidgets('About: C opens the credits', (t) async {
      final opened = <bool>[];
      await t.pumpWidget(MaterialApp(home: Scaffold(body: AboutOverlay(onClose: () {}, onCredits: () => opened.add(true)))));
      await t.pump();
      expect(t.takeException(), isNull); // 800x600: no overflow
      expect(find.text('Click or press Esc to close, C for credits'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.keyC);
      expect(opened, [true]);
    });
  });
}
