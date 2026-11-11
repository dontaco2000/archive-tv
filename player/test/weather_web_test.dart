import 'dart:async';
import 'dart:convert';

import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/weather_web.dart';
import 'package:archive_tv_player/ui/weatherstar.dart';
import 'package:archive_tv_player/weather/weather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WeatherStar URL: kiosk, silent, location, all displays with radar and Future Radar', () {
    final u = weatherStarUrl(place: 'Hattiesburg, Mississippi', lat: 31.3271, lon: -89.2903);
    final q = u.queryParameters;
    expect('${u.scheme}://${u.host}${u.path}', weatherStarSite);
    expect(q['kiosk'], 'true');
    expect(q['mediaPlaying'], 'false');
    expect(q['mediaVolume'], '0');
    expect(q['viewMode'], 'standard');
    expect(q['latLonQuery'], 'Hattiesburg, Mississippi');
    expect(jsonDecode(q['latLon']!), {'lat': 31.3271, 'lon': -89.2903});
    for (final d in ['radar', 'future-radar', 'current-weather', 'local-forecast', 'extended-forecast', 'regional-forecast']) {
      expect(q[d], 'true', reason: d);
    }
  });

  test('light WeatherStar URL keeps radar but drops Future Radar and map screens', () {
    final q = weatherStarUrl(place: 'X', lat: 1, lon: 2, light: true).queryParameters;
    expect(q['radar'], 'true');
    expect(q['current-weather'], 'true');
    for (final d in ['future-radar', 'regional-forecast', 'latest-observations', 'almanac', 'spc-outlook']) {
      expect(q[d], 'false', reason: d);
    }
  });

  test('fallback choice: web unless native is set, there is no WebView, or the page failed', () {
    expect(useWebWeather('web', webAvailable: true, pageFailed: false), isTrue);
    expect(useWebWeather('native', webAvailable: true, pageFailed: false), isFalse);
    expect(useWebWeather('web', webAvailable: false, pageFailed: false), isFalse);
    expect(useWebWeather('web', webAvailable: true, pageFailed: true), isFalse);
  });

  testWidgets('weather layers: page and native cover coexist in the Stack without key clashes', (t) async {
    Future<void> pump({required bool web, required bool loaded}) => t.pumpWidget(MaterialApp(
          home: Stack(fit: StackFit.expand, children: [
            const SizedBox(), // stands in for the video
            WeatherLayers(
              place: 'Hattiesburg, Mississippi',
              web: web,
              webLoaded: loaded,
              url: weatherStarUrl(place: 'Hattiesburg, Mississippi', lat: 31.3, lon: -89.3),
              load: () => Completer<WeatherReport>().future,
              onLoaded: () {},
              onFailed: (_) {},
              webViewForTest: (k) => ColoredBox(key: k, color: Colors.blue),
            ),
          ]),
        ));
    await pump(web: true, loaded: false); // loading: page under the native cover
    expect(t.takeException(), isNull);
    expect(find.byType(ColoredBox), findsWidgets);
    expect(find.byType(WeatherStarScreen), findsOneWidget);
    await pump(web: true, loaded: true);
    expect(find.byType(WeatherStarScreen), findsNothing);
    await pump(web: false, loaded: false); // native / fallback
    expect(find.byType(WeatherStarScreen), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  test('weatherMode defaults to web, round-trips, and ignores junk', () {
    expect(Settings().weatherMode, 'web');
    expect(Settings.fromJson((Settings()..weatherMode = 'native').toJson()).weatherMode, 'native');
    expect(Settings.fromJson({'weatherMode': 'bogus'}).weatherMode, 'web');
  });
}
