import 'dart:convert';
import 'dart:io';

class Settings {
  Set<int> favorites = {};
  double volume = 80;
  bool muted = false;
  bool startFullscreen = false;
  bool cornerBug = false; // spec 5.10: off by default
  bool favoritesOnly = false;
  double? windowX, windowY, windowW, windowH;
  bool fullscreen = false;

  /// The channel watched last; the app starts there.
  int? lastChannel;

  /// Weather channel location (Open-Meteo); set from the menu by city or ZIP.
  String weatherPlace = 'Hattiesburg, Mississippi';
  double weatherLat = 31.3271;
  double weatherLon = -89.2903;

  /// Weather channel picture: 'web' (the real WeatherStar 4000+ page) or 'native' (the app's own screens,
  /// also the fallback when the page can't load).
  String weatherMode = 'web';

  Settings();

  Map<String, dynamic> toJson() => {
        'favorites': favorites.toList()..sort(),
        'volume': volume,
        'muted': muted,
        'startFullscreen': startFullscreen,
        'cornerBug': cornerBug,
        'favoritesOnly': favoritesOnly,
        'windowX': windowX,
        'windowY': windowY,
        'windowW': windowW,
        'windowH': windowH,
        'fullscreen': fullscreen,
        'lastChannel': lastChannel,
        'weatherPlace': weatherPlace,
        'weatherLat': weatherLat,
        'weatherLon': weatherLon,
        'weatherMode': weatherMode,
      };

  factory Settings.fromJson(Map<String, dynamic> j) {
    final s = Settings();
    double? num_(String k) => j[k] is num ? (j[k] as num).toDouble() : null;
    bool bool_(String k, bool d) => j[k] is bool ? j[k] as bool : d;
    if (j['favorites'] is List) {
      s.favorites = (j['favorites'] as List).whereType<int>().toSet();
    }
    final v = num_('volume');
    if (v != null) s.volume = v.clamp(0, 100).toDouble();
    s.muted = bool_('muted', s.muted);
    s.startFullscreen = bool_('startFullscreen', s.startFullscreen);
    s.cornerBug = bool_('cornerBug', s.cornerBug);
    s.favoritesOnly = bool_('favoritesOnly', s.favoritesOnly);
    s.windowX = num_('windowX');
    s.windowY = num_('windowY');
    s.windowW = num_('windowW');
    s.windowH = num_('windowH');
    s.fullscreen = bool_('fullscreen', s.fullscreen);
    s.lastChannel = j['lastChannel'] is int ? j['lastChannel'] as int : null;
    final lat = num_('weatherLat'), lon = num_('weatherLon');
    if (j['weatherPlace'] is String && lat != null && lon != null) {
      s.weatherPlace = j['weatherPlace'] as String;
      s.weatherLat = lat;
      s.weatherLon = lon;
    }
    if (const {'web', 'native'}.contains(j['weatherMode'])) s.weatherMode = j['weatherMode'] as String;
    return s;
  }
}

class SettingsStore {
  final File file;
  SettingsStore(this.file);

  Settings load() {
    try {
      final j = jsonDecode(file.readAsStringSync());
      if (j is Map<String, dynamic>) return Settings.fromJson(j);
    } catch (_) {}
    return Settings();
  }

  void save(Settings s) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(jsonEncode(s.toJson()), flush: true);
    tmp.renameSync(file.path);
  }
}

/// Returns true if the channel is now a favorite.
bool toggleFavorite(Settings s, int channelNumber) {
  if (s.favorites.remove(channelNumber)) return false;
  s.favorites.add(channelNumber);
  return true;
}
