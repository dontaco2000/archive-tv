import 'dart:convert';

import 'package:http/http.dart' as http;

/// Weather for the Cumulus channel: Open-Meteo (free, no key, worldwide) plus active NWS alerts
/// (free, no key, US only; anywhere else, or on any failure, simply no alerts). Same data and model as the
/// Archive TV Server's weather channel (modules/guidechannel/lib/src/weather.dart).

/// One hour of the hourly forecast.
class HourForecast {
  final DateTime time;
  final double temp;
  final int code;
  final int? rainChance;
  const HourForecast(this.time, this.temp, this.code, this.rainChance);
}

/// One day of the forecast.
class DayForecast {
  final DateTime date;
  final int code;
  final double hi, lo;
  final int? rainChance;
  final DateTime? sunrise, sunset;
  final double? uvMax, windMax;
  const DayForecast(this.date, this.code, this.hi, this.lo, this.rainChance,
      {this.sunrise, this.sunset, this.uvMax, this.windMax});

  String get condition => wmoText(code);
}

/// An active weather alert (NWS).
class WeatherAlert {
  final String event, headline;
  const WeatherAlert(this.event, this.headline);
}

class WeatherReport {
  final String place;
  final bool imperial;

  /// When the data was fetched (the "UPDATED" note).
  final DateTime fetched;
  final double temp, feels, dew;
  final int humidity, code;
  final double windSpeed, windDir;
  final double? gusts;

  /// Pressure in inHg (imperial) or hPa; visibility in miles or km.
  final double pressure, visibility;
  final bool isDay;
  final List<HourForecast> hours;
  final List<DayForecast> days;
  final List<WeatherAlert> alerts;

  const WeatherReport({
    required this.place,
    this.imperial = true,
    required this.fetched,
    required this.temp,
    required this.feels,
    required this.dew,
    required this.humidity,
    required this.code,
    required this.windSpeed,
    required this.windDir,
    this.gusts,
    required this.pressure,
    required this.visibility,
    this.isDay = true,
    this.hours = const [],
    this.days = const [],
    this.alerts = const [],
  });

  String get condition => wmoText(code);
  String get speedUnit => imperial ? 'MPH' : 'KM/H';

  /// "SW 12" or "Calm".
  String get wind => windSpeed.round() == 0 ? 'Calm' : '${compass(windDir)} ${windSpeed.round()}';

  /// Parses an Open-Meteo `/v1/forecast` response asked for with `timeformat=unixtime` (see [forecastUri]) and,
  /// optionally, an NWS `/alerts/active` GeoJSON response. Missing fields read as 0 / empty, never throw on them.
  factory WeatherReport.fromOpenMeteo(Map<String, dynamic> meteo, String place,
      {bool imperial = true, DateTime? fetched, Map<String, dynamic>? alerts}) {
    final c = (meteo['current'] as Map?)?.cast<String, dynamic>() ?? const {};
    final h = (meteo['hourly'] as Map?)?.cast<String, dynamic>() ?? const {};
    final d = (meteo['daily'] as Map?)?.cast<String, dynamic>() ?? const {};
    double n(Object? v) => (v as num?)?.toDouble() ?? 0;
    double? opt(Object? v) => (v as num?)?.toDouble();
    Object? at(Map<String, dynamic> m, String k, int i) => (m[k] as List?)?.elementAtOrNull(i);
    DateTime? time(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000) : null;
    final hPa = n(c['pressure_msl']), metres = n(c['visibility']);
    return WeatherReport(
      place: place,
      imperial: imperial,
      fetched: fetched ?? DateTime.now(),
      temp: n(c['temperature_2m']),
      feels: n(c['apparent_temperature']),
      dew: n(c['dew_point_2m']),
      humidity: n(c['relative_humidity_2m']).round(),
      code: n(c['weather_code']).round(),
      windSpeed: n(c['wind_speed_10m']),
      windDir: n(c['wind_direction_10m']),
      gusts: opt(c['wind_gusts_10m']),
      pressure: imperial ? hPa * 0.02953 : hPa,
      visibility: imperial ? metres / 1609.344 : metres / 1000,
      isDay: c['is_day'] != 0,
      hours: [
        for (var i = 0; i < ((h['time'] as List?)?.length ?? 0); i++)
          if (time(at(h, 'time', i)) case final t?)
            HourForecast(t, n(at(h, 'temperature_2m', i)), n(at(h, 'weather_code', i)).round(),
                (at(h, 'precipitation_probability', i) as num?)?.round()),
      ],
      days: [
        for (var i = 0; i < ((d['time'] as List?)?.length ?? 0); i++)
          if (time(at(d, 'time', i)) case final t?)
            DayForecast(t, n(at(d, 'weather_code', i)).round(), n(at(d, 'temperature_2m_max', i)),
                n(at(d, 'temperature_2m_min', i)), (at(d, 'precipitation_probability_max', i) as num?)?.round(),
                sunrise: time(at(d, 'sunrise', i)),
                sunset: time(at(d, 'sunset', i)),
                uvMax: opt(at(d, 'uv_index_max', i)),
                windMax: opt(at(d, 'wind_speed_10m_max', i))),
      ],
      alerts: [
        for (final f in (alerts?['features'] as List?) ?? const [])
          if ((f as Map)['properties'] case final Map p when p['event'] is String)
            WeatherAlert(p['event'] as String, (p['headline'] as String?) ?? ''),
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

Uri forecastUri(Place p, {bool imperial = true}) => Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': '${p.lat}',
      'longitude': '${p.lon}',
      'current': 'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,'
          'wind_direction_10m,wind_gusts_10m,pressure_msl,visibility,dew_point_2m,is_day',
      'hourly': 'temperature_2m,weather_code,precipitation_probability',
      'daily': 'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,'
          'uv_index_max,wind_speed_10m_max',
      'temperature_unit': imperial ? 'fahrenheit' : 'celsius',
      'wind_speed_unit': imperial ? 'mph' : 'kmh',
      'timezone': 'auto',
      'timeformat': 'unixtime',
      'forecast_days': '7',
      'forecast_hours': '24',
    });

Uri alertsUri(Place p) =>
    Uri.https('api.weather.gov', '/alerts/active', {'point': '${p.lat.toStringAsFixed(4)},${p.lon.toStringAsFixed(4)}'});

/// The forecast (throws when Open-Meteo fails) plus NWS alerts (any failure: no alerts).
Future<WeatherReport> fetchWeather(http.Client client, Place p, {bool imperial = true}) async {
  final uri = forecastUri(p, imperial: imperial);
  final res = await client.get(uri, headers: _ua).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) throw http.ClientException('weather HTTP ${res.statusCode}', uri);
  Map<String, dynamic>? alerts;
  try {
    final a = await client.get(alertsUri(p), headers: {..._ua, 'Accept': 'application/geo+json'}).timeout(const Duration(seconds: 10));
    if (a.statusCode == 200) alerts = jsonDecode(a.body) as Map<String, dynamic>;
  } on Object {
    // outside the US or offline: no alerts
  }
  return WeatherReport.fromOpenMeteo(jsonDecode(res.body) as Map<String, dynamic>, p.name, imperial: imperial, alerts: alerts);
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
