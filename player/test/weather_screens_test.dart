// Layout proof for the Cumulus weather screens (compare with the Plex server's
// D:\Claude Projects\Archive TV Server\_build\weather-shots\). Runs (and passes) always; writes PNGs only when
// WEATHER_SHOTS (or MENU_SHOTS) names a folder:
//   $env:WEATHER_SHOTS='D:\Claude Projects\Archive TV\_build\screens'; flutter test test/weather_screens_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive_tv_player/ui/cumulus_weather.dart';
import 'package:archive_tv_player/weather/weather.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'weather_test.dart' show fixtureNow, report, sampleAlerts;

void main() {
  final out = Platform.environment['WEATHER_SHOTS'] ?? Platform.environment['MENU_SHOTS'];

  setUpAll(() async {
    // Real Arial when this PC has it (the screens' font on Windows), so the PNGs show text, not test boxes.
    for (final f in [r'C:\Windows\Fonts\arial.ttf']) {
      if (File(f).existsSync()) {
        final loader = FontLoader('Arial')..addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
        await loader.load();
      }
    }
  });

  // 1080p TV (4:3 pillarboxed) and a phone's 4:3 video box (portrait, full width, 2.625 dpr).
  for (final (name, size, dpr) in [('1080p', const Size(1920, 1080), 1.0), ('phone', const Size(1080, 810), 2.625)]) {
    for (final (label, load) in <(String, Future<WeatherReport> Function())>[
      ('', () async => report()),
      ('alerts-', () async => report(alerts: sampleAlerts)),
      ('nodata-', () async => throw const SocketException('offline')),
    ]) {
      testWidgets('weather screenshots $label$name', (t) async {
        t.view.physicalSize = size;
        t.view.devicePixelRatio = dpr;
        addTearDown(t.view.reset);
        final boundary = GlobalKey();
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(
            key: boundary,
            child: CumulusWeatherScreen(load: load, place: 'Hattiesburg, MS', clock: () => fixtureNow),
          ),
        ));
        final ctx = t.element(find.byType(CumulusWeatherScreen));
        await t.runAsync(() async {
          await precacheImage(const AssetImage('assets/branding/wordmark.png'), ctx);
          await precacheImage(ResizeImage(const AssetImage('assets/logos/cumulus.png'), width: 240), ctx);
        });
        await t.pump();

        Future<void> shot(String suffix) async {
          await t.pump();
          expect(t.takeException(), isNull);
          if (out == null) return;
          await t.runAsync(() async {
            final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
            final png = await (await ro.toImage(pixelRatio: dpr)).toByteData(format: ui.ImageByteFormat.png);
            File('$out${Platform.pathSeparator}weather-app-$name-$label$suffix.png').writeAsBytesSync(png!.buffer.asUint8List());
          });
        }

        final pages = label == 'nodata-' ? ['none'] : [if (label == 'alerts-') 'alerts', 'now', 'hourly', 'today', 'extended'];
        for (final (i, p) in pages.indexed) {
          await shot(p);
          if (label != '' || i == pages.length - 1) break; // the alerts and no-data runs need only their first screen
          await t.pump(CumulusWeatherScreen.hold);
          await t.pump(); // the slide starts
          if (i == 0) {
            await t.pump(const Duration(milliseconds: 500));
            await shot('slide'); // halfway from NOW to HOURLY
            await t.pump(const Duration(milliseconds: 500));
          } else {
            await t.pump(CumulusWeatherScreen.slide);
          }
          await t.pump(CumulusWeatherScreen.slide);
        }
        await t.pumpWidget(const SizedBox()); // stops the timers
      });
    }
  }
}
