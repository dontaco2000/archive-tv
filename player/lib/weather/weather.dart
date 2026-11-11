import 'dart:convert';

import 'package:http/http.dart' as http;

/// Weather for the Cumulus channel, from Open-Meteo (free, no key, worldwide).
class DayForecast {
  final DateTime date;
  final int code;
  final double hiF, loF;
  final int? rainChance;

  const DayForecast(this.date, this.code, this.hiF, this.loF, this.rainChance);

  String get condition => wmoText(code);
}

class WeatherReport {
  final String place;
  final double tempF, feelsF, dewF;
  final int humidity, code;
  final String wind;
  final double pressureInHg, visibilityMi;
  final List<DayForecast> days;

  const WeatherReport({
    required this.place,
    required this.tempF,
    required this.feelsF,
    required this.dewF,
    required this.humidity,
    required this.code,
    required this.wind,
    required this.pressureInHg,
    required this.visibilityMi,
    required this.days,
  });

  String get condition => wmoText(code);

  factory WeatherReport.fromOpenMeteo(Map<String, dynamic> j, String place) {
    final c = j['current'] as Map<String, dynamic>;
    final d = j['daily'] as Map<String, dynamic>;
    double n(Object? v) => (v as num?)?.toDouble() ?? 0;
    List<Object?> col(String k) => (d[k] as List?) ?? const [];
    final times = col('time');
    final speed = n(c['wind_speed_10m']).round();
    return WeatherReport(
      place: place,
      tempF: n(c['temperature_2m']),
      feelsF: n(c['apparent_temperature']),
      dewF: n(c['dew_point_2m']),
      humidity: n(c['relative_humidity_2m']).round(),
      code: n(c['weather_code']).round(),
      wind: speed == 0 ? 'Calm' : '${compass(n(c['wind_direction_10m']))} $speed',
      pressureInHg: n(c['pressure_msl']) * 0.02953,
      visibilityMi: n(c['visibility']) / 1609.344,
      days: [
        for (var i = 0; i < times.length; i++)
          DayForecast(
            DateTime.parse(times[i] as String),
            n(col('weather_code')[i]).round(),
            n(col('temperature_2m_max')[i]),
            n(col('temperature_2m_min')[i]),
            (col('precipitation_probability_max').elementAtOrNull(i) as num?)?.round(),
          ),
      ],
    );
  }
}

/// A named place with coordinates.
class Place {
  final String name;
  final double lat, lon;
  const Place(this.name, this.lat, this.lon);
}

const _ua = {'User-Agent': 'ArchiveTV/0.2 (personal TV app)'};

Future<WeatherReport> fetchWeather(http.Client client, Place p) async {
  final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
    'latitude': '${p.lat}',
    'longitude': '${p.lon}',
    'current': 'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,'
        'wind_direction_10m,pressure_msl,visibility,dew_point_2m',
    'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
    'temperature_unit': 'fahrenheit',
    'wind_speed_unit': 'mph',
    'timezone': 'auto',
    'forecast_days': '6',
  });
  final res = await client.get(uri, headers: _ua).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) throw http.ClientException('weather HTTP ${res.statusCode}', uri);
  return WeatherReport.fromOpenMeteo(jsonDecode(res.body) as Map<String, dynamic>, p.name);
}

/// Looks up a city name or ZIP code; US matches first, then anywhere. Null if nothing matches.
Future<Place?> geocode(http.Client client, String query) async {
  for (final country in ['US', null]) {
    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': query.trim(),
      'count': '1',
      'countryCode': ?country,
    });
    final res = await client.get(uri, headers: _ua).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) continue;
    final r = ((jsonDecode(res.body) as Map<String, dynamic>)['results'] as List?)?.firstOrNull;
    if (r is Map<String, dynamic>) {
      final region = r['admin1'] as String?;
      return Place([r['name'], ?region].join(', '), (r['latitude'] as num).toDouble(), (r['longitude'] as num).toDouble());
    }
  }
  return null;
}

String compass(double deg) => const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][((deg % 360) / 45).round() % 8];

/// WMO weather code to short TV wording.
String wmoText(int code) => switch (code) {
      0 => 'Sunny',
      1 => 'Mostly Sunny',
      2 => 'Partly Cloudy',
      3 => 'Cloudy',
      45 || 48 => 'Fog',
      51 || 53 || 55 || 56 || 57 => 'Drizzle',
      61 || 63 || 66 || 80 || 81 => 'Rain',
      65 || 67 || 82 => 'Heavy Rain',
      71 || 73 || 75 || 77 || 85 || 86 => 'Snow',
      95 || 96 || 99 => 'T-Storms',
      _ => 'Unknown',
    };
