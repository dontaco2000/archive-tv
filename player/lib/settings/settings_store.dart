import 'dart:convert';
import 'dart:io';

import '../player/picture.dart';

class Settings {
  Set<int> favorites = {};
  double volume = 80;
  /// Mute lasts for this run only: the app always starts unmuted (not saved, not restored).
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

  /// Remote control reachable from phones on the LAN (off: this PC only), and its 4-digit PIN.
  bool remoteLan = false;
  String? remotePin;

  /// Evens out loudness between channels and programs: 'off', 'normal' or 'strong' (see [levelingFilter]).
  String volumeLeveling = 'normal';

  /// The one-time content notice was shown and dismissed.
  bool noticeAccepted = false;

  /// Captions on English programmes (foreign ones always get English subtitles), and the caption size step 1-7.
  bool captionsOn = false;
  int captionSize = 4;

  /// Picture: 'auto' (crop baked-in black borders), 'fill' (also cover the frame) or 'off' (see picture.dart).
  String picture = 'auto';

  /// A/V sync nudges: Archive item id -> audio delay in ms (+ = audio later). Only non-zero ones are kept.
  Map<String, int> audioDelays = {};

  Settings();

  Map<String, dynamic> toJson() => {
        'favorites': favorites.toList()..sort(),
        'volume': volume,
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
        'remoteLan': remoteLan,
        'remotePin': remotePin,
        'volumeLeveling': volumeLeveling,
        'noticeAccepted': noticeAccepted,
        'captionsOn': captionsOn,
        'captionSize': captionSize,
        'picture': picture,
        'audioDelays': audioDelays,
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
    s.remoteLan = bool_('remoteLan', s.remoteLan);
    final pin = j['remotePin'];
    if (pin is String && RegExp(r'^\d{4}$').hasMatch(pin)) s.remotePin = pin;
    if (levelingModes.contains(j['volumeLeveling'])) s.volumeLeveling = j['volumeLeveling'] as String;
    s.noticeAccepted = bool_('noticeAccepted', s.noticeAccepted);
    s.captionsOn = bool_('captionsOn', s.captionsOn);
    if (pictureModes.contains(j['picture'])) s.picture = j['picture'] as String;
    if (j['audioDelays'] is Map) {
      for (final MapEntry(:key, :value) in (j['audioDelays'] as Map).entries) {
        if (key is String && value is int && value != 0) s.audioDelays[key] = value.clamp(-maxAudioDelayMs, maxAudioDelayMs);
      }
    }
    if (j['captionSize'] is int) s.captionSize = (j['captionSize'] as int).clamp(1, 7);
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

/// A/V sync nudge step and limit (ms).
const audioDelayStepMs = 50, maxAudioDelayMs = 3000;

/// Shifts the saved audio delay of [itemId] by [stepMs] (0 = reset to none); returns the new delay in ms.
int nudgeAudioDelay(Settings s, String itemId, int stepMs) {
  final ms = stepMs == 0 ? 0 : ((s.audioDelays[itemId] ?? 0) + stepMs).clamp(-maxAudioDelayMs, maxAudioDelayMs);
  if (ms == 0) {
    s.audioDelays.remove(itemId);
  } else {
    s.audioDelays[itemId] = ms;
  }
  return ms;
}

const levelingModes = ['off', 'normal', 'strong'];

/// The leveling mode [dir] steps (+1/-1, wrapping) from [current].
String cycleLeveling(String current, int dir) {
  final i = levelingModes.indexOf(current);
  return levelingModes[((i < 0 ? 1 : i) + dir) % levelingModes.length];
}

/// mpv `af` value for a leveling mode ('' = no filter). Plain filter names (not `lavfi=[...]`), so mpv
/// rejects a filter its libavfilter lacks when the property is set, instead of failing later and dropping audio. Tuned on Archive samples, see _build/leveling-report.md:
/// normal = dynaudnorm aiming at an RMS level (channel-to-channel spread 16.5 LU -> 2.7 LU),
/// strong = faster dynaudnorm + compressor + limiter (also flattens loud/quiet moments within a program).
String levelingFilter(String mode) => switch (mode) {
      'normal' => 'dynaudnorm=f=250:g=15:p=0.9:m=10:r=0.15',
      'strong' => 'dynaudnorm=f=100:g=7:p=0.9:m=20:r=0.15,'
          'acompressor=threshold=-22dB:ratio=4:attack=10:release=200:makeup=1.6,alimiter=limit=0.95',
      _ => '',
    };
