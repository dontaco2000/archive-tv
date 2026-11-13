// Phone / tablet touch UI (ui/touch.dart). Layout at phone, tablet and TV sizes, the on-screen remote's keys, and
// touch in the guide, menu and PIN prompt. Screenshots only when TOUCH_SHOTS names a folder:
//   $env:TOUCH_SHOTS='D:\...\_build\screens'; flutter test test/touch_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/engine/tv_engine.dart' show Airing;
import 'package:archive_tv_player/guide/guide_model.dart';
import 'package:archive_tv_player/parental/parental_flow.dart';
import 'package:archive_tv_player/parental/parental_ui.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/guide_overlay.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:archive_tv_player/ui/touch.dart';
import 'package:archive_tv_player/ui/tv_screen.dart' show InfoBanner;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const funnies = Channel(number: 2, name: 'Funnies', genre: 'Kids & Animation');

Slot slot(String title, DateTime start, int minutes) => Slot(
      Entry(id: title, itemId: title, file: '$title.mp4', title: title, durationSeconds: minutes * 60.0, url: 'u'),
      start,
      start.add(Duration(minutes: minutes)),
    );

final remoteState = <String, Object?>{
  'channel': {'number': 2, 'name': 'Funnies'},
  'title': 'Looney Tunes - Duck Amuck',
  'minutesLeft': 4,
  'volume': 60,
  'muted': false,
  'favorite': true,
  'sleep': 30,
};

/// A touch button by its label (symbol words draw as icons, so not findable as text).
Finder btn(String label) => find.byWidgetPredicate((w) => w is TouchButton && w.label == label);

void main() {
  final out = Platform.environment['TOUCH_SHOTS'];
  final shotKey = GlobalKey();

  setUpAll(() async {
    // Real fonts when this PC has them, so the PNGs show text and icons instead of test boxes (Android draws
    // the keys in Roboto). Without them the tests still run.
    final fonts = Platform.environment['FLUTTER_ROOT'] ?? r'C:\srclutter';
    for (final (family, files) in [
      ('Consolas', [r'C:\Windows\Fonts\consola.ttf', r'C:\Windows\Fonts\consolab.ttf']),
      ('Roboto', ['$fonts/bin/cache/artifacts/material_fonts/roboto-regular.ttf', '$fonts/bin/cache/artifacts/material_fonts/roboto-medium.ttf', '$fonts/bin/cache/artifacts/material_fonts/roboto-bold.ttf']),
      ('MaterialIcons', ['$fonts/bin/cache/artifacts/material_fonts/materialicons-regular.otf']),
    ]) {
      final loader = FontLoader(family);
      for (final f in files) {
        if (File(f).existsSync()) loader.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
      }
      await loader.load();
    }
  });

  test('device class: TV wins, then 600 dp shortest side = tablet', () {
    expect(deviceKind(tv: true, size: const Size(1280, 800)), DeviceKind.tv);
    expect(deviceKind(tv: false, size: const Size(412, 915)), DeviceKind.phone);
    expect(deviceKind(tv: false, size: const Size(915, 412)), DeviceKind.phone);
    expect(deviceKind(tv: false, size: const Size(800, 1280)), DeviceKind.tablet);
    expect(deviceKind(tv: false, size: const Size(1280, 800)), DeviceKind.tablet);
  });

  test('touchSplit: portrait video on top at full width, landscape remote on the right, full = no remote', () {
    var (v, r) = touchSplit(const Size(412, 870), 4 / 3);
    expect(v, const Rect.fromLTWH(0, 0, 412, 309));
    expect(r, const Rect.fromLTRB(0, 309, 412, 870));
    (v, r) = touchSplit(const Size(412, 870), 16 / 9);
    expect(v.width, 412);
    expect(v.height, closeTo(231.75, 0.01));
    // Landscape phone: the remote keeps 260 dp; the video is as big as the rest allows.
    (v, r) = touchSplit(const Size(870, 412), 16 / 9);
    expect(r!.left, 610);
    expect(r.width, 260);
    expect(v.right, lessThanOrEqualTo(r.left + 0.01));
    expect(v.width / v.height, closeTo(16 / 9, 0.001));
    // Wide tablet: the 4:3 video is full height and the remote gets what is left.
    (v, r) = touchSplit(const Size(1280, 752), 4 / 3);
    expect(v.height, 752);
    expect(r!.width, closeTo(1280 - 752 * 4 / 3, 0.01));
    // Tall portrait: the video never takes more than 55% of the height.
    (v, r) = touchSplit(const Size(600, 700), 4 / 3);
    expect(v.height, closeTo(385, 0.01));
    (v, r) = touchSplit(const Size(870, 412), 4 / 3, full: true);
    expect(r, isNull);
    expect(v.height, 412);
    expect(v.center.dx, closeTo(435, 0.01));
  });

  Future<List<LogicalKeyboardKey>> pumpLayout(WidgetTester t, Size size, {bool full = false, Widget? panel, double aspect = 4 / 3}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final pressed = <LogicalKeyboardKey>[];
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: shotKey,
        child: Scaffold(
        backgroundColor: Colors.black,
        body: TouchLayout(
          aspect: aspect,
          full: full,
          press: pressed.add,
          frame: Stack(fit: StackFit.expand, children: [
            Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF203040), Color(0xFF6A3018)]))),
            InfoBanner(
              channel: funnies,
              airing: Airing(funnies, slot('Looney Tunes - Duck Amuck', DateTime(2026, 11, 12, 20), 7), 180, null),
            ),
          ]),
          remote: TouchRemote(
            state: remoteState,
            channel: funnies,
            press: pressed.add,
            setVolume: (_) {},
            onPower: () {},
            onFullscreen: () {},
          ),
          panel: panel,
        ),
      )),
    ));
    await t.pump();
    return pressed;
  }

  final boundaryShots = <String, Size>{
    'phone-portrait': const Size(412, 870),
    'phone-landscape': const Size(870, 412),
    'tablet-portrait': const Size(800, 1232),
    'tablet-landscape': const Size(1280, 752),
  };

  Future<void> shot(WidgetTester t, String name) async {
    if (out == null) return;
    await t.pump();
    await t.runAsync(() async {
      final ro = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await ro.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$out${Platform.pathSeparator}touch-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  for (final MapEntry(key: name, value: size) in boundaryShots.entries) {
    testWidgets('layout $name: video and remote side by side, no overflow', (t) async {
      await pumpLayout(t, size);
      final video = t.getRect(find.byKey(TouchLayout.videoKey));
      final remote = t.getRect(find.byKey(TouchLayout.remoteKey));
      if (size.height > size.width) {
        expect(video.top, 0);
        expect(video.width, size.width);
        expect(remote.top, closeTo(video.bottom, 0.01));
      } else {
        expect(remote.left, greaterThanOrEqualTo(video.right - 0.01));
        expect(remote.right, size.width);
      }
      // The video box is always 4:3; the remote fills the rest: keys reach its bottom, no dead band.
      expect(video.width / video.height, closeTo(4 / 3, 0.001));
      expect(remote.bottom - t.getRect(btn('FULL')).bottom, lessThan(40));
      // Keys stay finger-sized: >= 40 px tall in portrait, >= 30 px on a short landscape phone.
      expect(t.getSize(btn('GUIDE')).height, greaterThanOrEqualTo(size.height > size.width ? 40 : 30));
      expect(t.takeException(), isNull);
      await shot(t, name);
    });
  }

  testWidgets('full: the remote is hidden and the video is as big as fits', (t) async {
    await pumpLayout(t, const Size(870, 412), full: true);
    expect(find.byKey(TouchLayout.remoteKey), findsNothing);
    expect(t.getRect(find.byKey(TouchLayout.videoKey)).height, 412);
  });

  testWidgets('remote buttons press the same keys as the Windows remote page', (t) async {
    final pressed = await pumpLayout(t, const Size(412, 870));
    for (final label in ['GUIDE', 'MENU', 'CH \u25B2', 'OK', 'LAST', 'SLEEP', 'PIC', 'MUTE', '+']) {
      await t.tap(btn(label));
    }
    expect(pressed, [
      LogicalKeyboardKey.keyG,
      LogicalKeyboardKey.keyM,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.keyL,
      LogicalKeyboardKey.keyT,
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyU,
      LogicalKeyboardKey.equal,
    ]);
    // 123 swaps the D-pad for the number pad: digits, then GO.
    pressed.clear();
    await t.tap(btn('123'));
    await t.pump();
    await t.tap(btn('4'));
    await t.tap(btn('2'));
    await t.tap(btn('GO'));
    expect(pressed, [LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit2, LogicalKeyboardKey.enter]);
    await shot(t, 'phone-numpad');
    await t.tap(btn('CLOSE'));
    await t.pump();
    expect(btn('CH \u25B2'), findsOneWidget);
  });

  testWidgets('an open panel covers the screen with BACK and the D-pad under it', (t) async {
    final pressed = await pumpLayout(t, const Size(412, 870), panel: const SizedBox.expand());
    await t.tap(btn('BACK').last); // the bar's, not the remote's under the panel
    await t.tap(btn('\u25BC').last);
    await t.tap(btn('OK').last);
    expect(pressed, [LogicalKeyboardKey.escape, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.enter]);
  });

  // ---- touch inside the overlays (wrapped in TouchUi, as TouchLayout does).
  final now = DateTime(2026, 11, 11, 10, 15);
  final channels = [for (var n = 1; n <= 12; n++) Channel(number: n, name: 'Ch$n', genre: 'TV')];
  GuideModel guide() => GuideModel(
        channels: channels,
        now: now,
        tunableNumbers: {for (final c in channels) c.number},
        horizon: now.add(const Duration(days: 1)),
        slotsFor: (ch) => [slot('${ch.name} Show', DateTime(2026, 11, 11, 10), 60), slot('${ch.name} Late', DateTime(2026, 11, 11, 11), 600)],
      );

  Future<void> pumpPanel(WidgetTester t, Widget panel, {Size size = const Size(412, 870)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(backgroundColor: Colors.black, body: RepaintBoundary(key: shotKey, child: TouchUi(child: panel))),
    ));
    await t.pump();
  }

  testWidgets('guide by touch: full screen, more rows, drag scrolls, tap selects, tap again tunes', (t) async {
    final tuned = <Channel>[];
    final m = guide();
    await pumpPanel(t, GuideOverlay(model: m, onTune: tuned.add, onHighlight: (_) {}, onClose: () {}));
    expect(find.text('Ch9'), findsWidgets); // 870 px: 13 rows (TV shows 5)
    await shot(t, 'guide-phone');
    await t.drag(find.text('Ch5').last, const Offset(0, -250));
    await t.pump();
    expect(m.selectedRow, greaterThan(0));
    await t.tap(find.text('Ch3 Late'));
    await t.pump();
    expect(tuned, isEmpty);
    expect(m.selectedChannel.name, 'Ch3');
    expect(m.selectedSlot!.entry.title, 'Ch3 Late');
    expect(find.textContaining('Ch3 Late  11:00'), findsOneWidget); // the header has the full title + time
    await t.tap(find.text('Ch3 Late').last);
    expect(tuned.single.name, 'Ch3');
    await t.tap(find.text('Ch4').last); // a channel name tunes at once
    expect(tuned.last.name, 'Ch4');
    expect(t.takeException(), isNull);
  });

  testWidgets('menu by touch: tap opens a category, volume halves step down/up', (t) async {
    final s = Settings()..volume = 50;
    await pumpPanel(
      t,
      MenuOverlay(settings: s, current: funnies, onChanged: (_) {}, onBlockCurrent: () {}, onRefresh: () {}, onClose: () {}, onSleep: () {}, onParental: () {}),
    );
    await t.runAsync(() => precacheImage(const AssetImage(MenuOverlay.banner), t.element(find.byType(MenuOverlay))));
    await t.pump();
    await shot(t, 'menu-phone');
    await t.tap(find.text('Picture & Sound  >'));
    await t.pump();
    final vol = find.textContaining('Volume #');
    final r = t.getRect(vol.first);
    final row = t.getRect(find.ancestor(of: vol.first, matching: find.byType(Container)).first);
    await t.tapAt(Offset(row.right - 10, r.center.dy));
    await t.pump();
    expect(s.volume, 55);
    await t.tapAt(Offset(row.left + 10, r.center.dy));
    await t.pump();
    expect(s.volume, 50);
    await t.tap(find.text('Mute: OFF'));
    await t.pump();
    expect(s.muted, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('PIN by touch: a number pad types the four digits', (t) async {
    String? got;
    var cancelled = false;
    await pumpPanel(t, PinPrompt(request: PinRequest('PARENTAL LOCK', (p) => got = p), onCancel: () => cancelled = true));
    expect(find.byType(PinPad), findsOneWidget);
    for (final d in ['1', '9', '9']) {
      await t.tap(btn(d));
      await t.pump();
    }
    await shot(t, 'pin-phone');
    await t.tap(btn('\u232B'));
    await t.pump();
    await t.tap(btn('8'));
    await t.tap(btn('4'));
    await t.pump();
    expect(got, '1984');
    await t.tap(btn('CANCEL'));
    expect(cancelled, isTrue);
  });

  testWidgets('TV keeps the D-pad PIN picker (no number pad)', (t) async {
    t.view.physicalSize = const Size(960, 540);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: PinPrompt(request: PinRequest('PIN', (_) {}), onCancel: () {}))));
    expect(find.byType(PinPad), findsNothing);
  });
}
