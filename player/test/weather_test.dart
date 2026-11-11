import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_player/ui/weatherstar.dart';
import 'package:archive_tv_player/weather/weather.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> _fixture(String name) => jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final report = WeatherReport.fromOpenMeteo(_fixture('open_meteo.json'), 'Hattiesburg, MS');

  test('parses Open-Meteo current conditions and the daily forecast', () {
    expect(report.place, 'Hattiesburg, MS');
    expect(report.tempF, 58.6);
    expect(report.humidity, 79);
    expect(report.condition, 'Cloudy');
    expect(report.wind, 'N 3');
    expect(report.pressureInHg, closeTo(30.08, 0.01));
    expect(report.visibilityMi, closeTo(12.2, 0.1));
    expect(report.days, hasLength(6));
    expect(report.days.first.date, DateTime(2026, 11, 11));
    expect(report.days[1].condition, 'Sunny');
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

  testWidgets('WeatherStar cycles current conditions, local and extended forecast pages', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WeatherStarScreen(load: () async => report)));
    await tester.pump();
    expect(find.text('Current Conditions'), findsOneWidget);
    expect(find.textContaining('59'), findsWidgets); // 58.6 F rounds to 59
    await tester.pump(WeatherStarScreen.pageTime);
    expect(find.text('Local Forecast'), findsOneWidget);
    await tester.pump(WeatherStarScreen.pageTime);
    expect(find.text('Extended Forecast'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stops the timers
  });

  testWidgets('WeatherStar shows a message when the data cannot be loaded', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WeatherStarScreen(load: () async => throw const SocketException('offline'))));
    await tester.pump();
    expect(find.textContaining('unavailable'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
