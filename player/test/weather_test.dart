import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_player/ui/cumulus_weather.dart';
import 'package:archive_tv_player/weather/weather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Real Open-Meteo answer for Hattiesburg (2026-11-13 ~10:30 PM CST), asked for with [forecastUri].
final meteo = jsonDecode(File('test/fixtures/open_meteo_full.json').readAsStringSync()) as Map<String, dynamic>;
final fixtureNow = DateTime.fromMillisecondsSinceEpoch(1794630600 * 1000);
const sampleAlerts = {
  'features': [
    {
      'properties': {
        'event': 'Wind Advisory',
        'headline': 'Wind Advisory issued November 13 at 9:12PM CST until November 14 at 6:00PM CST by NWS Jackson MS',
      },
    },
  ],
};

WeatherReport report({String place = 'Hattiesburg, MS', bool imperial = true, Map<String, dynamic>? alerts}) =>
    WeatherReport.fromOpenMeteo(meteo, place,
        imperial: imperial, fetched: fixtureNow.subtract(const Duration(minutes: 1)), alerts: alerts);

/// One screen on: the 9 s hold, then the 1 s slide. The fake clock only starts the ticker a frame late,
/// so the slide gets two frames of its own length.
Future<void> nextScreen(WidgetTester t) async {
  await t.pump(CumulusWeatherScreen.hold);
  await t.pump(CumulusWeatherScreen.slide);
  await t.pump(CumulusWeatherScreen.slide);
}

Future<void> show(WidgetTester t, Future<WeatherReport> Function() load, {String place = ''}) async {
  await t.pumpWidget(MaterialApp(home: CumulusWeatherScreen(load: load, place: place, clock: () => fixtureNow)));
  await t.pump();
}

void main() {
  test('parses current conditions, hourly, daily (unixtime) and NWS alerts', () {
    final r = report(alerts: sampleAlerts);
    expect(r.temp, 43.0);
    expect(r.humidity, 62);
    expect(r.condition, 'Partly Cloudy');
    expect(r.isDay, isFalse);
    expect(r.wind, 'N 5');
    expect(r.gusts, 10.3);
    expect(r.pressure, closeTo(30.07, 0.01));
    expect(r.visibility, closeTo(18.4, 0.1));
    expect(r.hours, hasLength(24));
    expect(r.days, hasLength(7));
    expect(r.days.first.sunrise, isNotNull);
    expect(r.days.first.uvMax, closeTo(4.85, 0.001));
    expect(r.alerts.single.event, 'Wind Advisory');
  });

  test('metric keeps hPa and km; missing fields read as 0 / empty', () {
    final m = report(imperial: false);
    expect(m.pressure, closeTo(1018.3, 0.01));
    expect(m.visibility, closeTo(29.6, 0.01));
    expect(m.speedUnit, 'KM/H');
    final empty = WeatherReport.fromOpenMeteo(const {}, 'X');
    expect([empty.temp, empty.hours, empty.days, empty.alerts], [0, isEmpty, isEmpty, isEmpty]);
  });

  test('fetchWeather asks for the Plex screens\' fields; a failed alerts call just means no alerts', () async {
    final asked = <Uri>[];
    var alertsOk = false;
    final client = MockClient((req) async {
      asked.add(req.url);
      if (req.url.host == 'api.weather.gov') {
        if (!alertsOk) throw const SocketException('down');
        return http.Response(jsonEncode(sampleAlerts), 200);
      }
      return http.Response(jsonEncode(meteo), 200);
    });
    const p = Place('Hattiesburg, MS', 31.3271, -89.2903);
    expect((await fetchWeather(client, p)).alerts, isEmpty);
    final q = asked.first.queryParameters;
    for (final f in ['wind_gusts_10m', 'is_day', 'dew_point_2m', 'visibility', 'pressure_msl']) {
      expect(q['current'], contains(f));
    }
    expect(q['hourly'], contains('precipitation_probability'));
    expect(q['daily'], allOf(contains('sunrise'), contains('uv_index_max'), contains('wind_speed_10m_max')));
    expect(q['timeformat'], 'unixtime');
    expect(asked[1].queryParameters['point'], '31.3271,-89.2903');
    alertsOk = true;
    expect((await fetchWeather(client, p)).alerts.single.event, 'Wind Advisory');
    expect(fetchWeather(MockClient((_) async => http.Response('', 503)), p), throwsA(isA<http.ClientException>()));
  });

  test('WMO codes map to short TV wording', () {
    expect(wmoText(0), 'Sunny');
    expect(wmoText(2), 'Partly Cloudy');
    expect(wmoText(61), 'Rain');
    expect(wmoText(95), 'T-Storms');
    expect(wmoText(999), 'Unknown');
  });

  test('geocode prefers a US match and reads the place name', () async {
    final asked = <Uri>[];
    final client = MockClient((req) async {
      asked.add(req.url);
      return http.Response(File('test/fixtures/geocode.json').readAsStringSync(), 200);
    });
    final p = (await geocode(client, '39401'))!;
    expect(asked.single.queryParameters['countryCode'], 'US');
    expect(p.name, 'Hattiesburg, Mississippi');
    expect(p.lat, closeTo(31.327, 0.001));
    expect(p.lon, closeTo(-89.290, 0.001));
  });

  test('screens: alerts first only when there are alerts', () {
    expect(weatherPages(null), [WeatherPage.none]);
    expect(weatherPages(report()), [WeatherPage.current, WeatherPage.hourly, WeatherPage.today, WeatherPage.extended]);
    expect(weatherPages(report(alerts: sampleAlerts)).first, WeatherPage.alerts);
  });

  testWidgets('cycles NOW, HOURLY, TODAY, EXTENDED with the header and tab strip', (t) async {
    await show(t, () async => report());
    expect(find.text('HATTIESBURG, MS'), findsOneWidget);
    expect(find.text('UPDATED 10:29 PM'), findsOneWidget);
    expect(find.text('FRI NOV 13'), findsOneWidget);
    for (final tab in ['NOW', 'HOURLY', 'TODAY', 'EXTENDED']) {
      expect(find.text(tab), findsOneWidget);
    }
    expect(find.text('CURRENT CONDITIONS'), findsOneWidget);
    for (final s in ['43°', 'Partly Cloudy', 'FEELS LIKE 37°', '62%', '31°', 'N 5 MPH', '10 MPH', '30.07 in', '18 mi']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    await nextScreen(t);
    expect(find.text('HOURLY FORECAST'), findsOneWidget);
    expect(find.text('10 PM'), findsOneWidget);
    expect(find.text('5 AM'), findsOneWidget);
    await nextScreen(t);
    expect(find.text("TODAY'S FORECAST"), findsOneWidget);
    expect(find.text('SUNRISE'), findsOneWidget);
    expect(find.text('WIND UP TO'), findsOneWidget);
    await nextScreen(t);
    expect(find.text('EXTENDED FORECAST'), findsOneWidget);
    for (final d in ['SAT', 'SUN', 'MON', 'TUE', 'WED', 'THU']) {
      expect(find.text(d), findsOneWidget, reason: d);
    }
    await nextScreen(t);
    expect(find.text('CURRENT CONDITIONS'), findsOneWidget); // loops
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox()); // stops the timers
  });

  testWidgets('mid-slide both screens are on', (t) async {
    await show(t, () async => report());
    await t.pump(CumulusWeatherScreen.hold);
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    expect(find.text('HUMIDITY'), findsOneWidget);
    expect(find.text('CONDITIONS'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('alerts screen comes first with a red ALERTS tab', (t) async {
    await show(t, () async => report(alerts: sampleAlerts));
    expect(find.text('WEATHER ALERTS'), findsOneWidget);
    expect(find.text('ALERTS'), findsOneWidget);
    expect(find.text('WIND ADVISORY'), findsOneWidget);
    await nextScreen(t);
    expect(find.text('CURRENT CONDITIONS'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('no data: loading, then WEATHER DATA NOT AVAILABLE', (t) async {
    await show(t, () async => throw const SocketException('offline'), place: 'Hattiesburg, Mississippi');
    expect(find.text('WEATHER DATA NOT AVAILABLE'), findsOneWidget);
    expect(find.text('LOCAL WEATHER'), findsOneWidget);
    expect(find.text('HATTIESBURG, MISSISSIPPI'), findsOneWidget);
    await nextScreen(t); // the single screen stays
    expect(find.text('WEATHER DATA NOT AVAILABLE'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('long city names stay on one line without overflow', (t) async {
    await show(t, () async => report(place: 'Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Wales'));
    expect(t.takeException(), isNull);
    final title = t.widget<Text>(find.textContaining('LLANFAIR'));
    expect((title.maxLines, title.overflow), (1, TextOverflow.ellipsis));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('metric units', (t) async {
    await show(t, () async => report(imperial: false));
    for (final s in ['N 5 KM/H', '1018 hPa', '30 km']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    await t.pumpWidget(const SizedBox());
  });
}
