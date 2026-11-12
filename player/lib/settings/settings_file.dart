import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../player/picture.dart';
import 'settings_store.dart';

/// archive_tv_settings.txt: a few safe settings as plain key=value lines anyone can edit, plus the one-shot
/// reset_parental_controls key, the ONLY way to reset parental controls. Read at startup (valid values override
/// settings.json, invalid ones are logged and ignored), then rewritten with the current values; the app keeps it
/// in step whenever settings are saved (SettingsStore.textFile).
const settingsFileName = 'archive_tv_settings.txt';

/// Windows: the data folder. Android: the app-specific external files dir
/// (/sdcard/Android/data/com.archivetv.player/files, reachable with adb or a file manager, no root), else [dataDir].
/// [external] false (tests, --data-dir runs) always uses [dataDir].
Future<File> settingsFileFor(Directory dataDir, {required bool external}) async {
  if (external) {
    try {
      final d = await getExternalStorageDirectory();
      if (d != null) {
        d.createSync(recursive: true);
        return File(p.join(d.path, settingsFileName));
      }
    } on Object {
      // no external storage: the internal data folder below
    }
  }
  return File(p.join(dataDir.path, settingsFileName));
}

String _b(bool v) => v ? 'true' : 'false';

/// The whole file for [s] (reset key always false).
String settingsFileText(Settings s) => '''
# Archive TV settings you can edit by hand.
# Close Archive TV first; changes are read at the next start. One key=value per line, # starts a comment.
# Invalid values are ignored (and noted in archive_tv.log). The app rewrites this file when settings change.

# true = at the next start, wipe ALL parental controls (PIN, locked channels, lock on/off, wrong-PIN count).
# It is the only way to reset a forgotten PIN. The app sets it back to false after the reset.
reset_parental_controls=false

# Windows only: start in fullscreen (true/false).
start_fullscreen=${_b(s.startFullscreen)}

# Weather channel picture: web (WeatherStar 4000+ page) or native (classic screens).
weather_mode=${s.weatherMode}

# Even out loudness between programs: off, normal or strong.
volume_leveling=${s.volumeLeveling}

# Picture: auto (crop black borders), fill (also fill the screen) or off.
picture=${s.picture}

# Windows only: let phones on the same Wi-Fi use the remote (true/false; the PIN is shown in the menu).
remote_on_wifi=${_b(s.remoteLan)}
''';

bool? _bool(String v) => switch (v.toLowerCase()) {
      'true' || 'yes' || 'on' || '1' => true,
      'false' || 'no' || 'off' || '0' => false,
      _ => null,
    };

/// Applies [text] to [s]. Returns true if parental controls were reset. Never throws.
bool applySettingsText(String text, Settings s, void Function(String) log) {
  var reset = false;
  for (final (i, raw) in text.split(RegExp(r'\r?\n')).indexed) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) {
      log('$settingsFileName line ${i + 1} ignored: not key=value');
      continue;
    }
    final key = line.substring(0, eq).trim().toLowerCase(), value = line.substring(eq + 1).trim().replaceFirst(RegExp(r'\s+#.*$'), '');
    final b = _bool(value), v = value.toLowerCase();
    var ok = true;
    switch (key) {
      case 'reset_parental_controls':
        if (b == null) {
          ok = false;
        } else if (b) {
          s.parental.clear();
          reset = true;
          log('parental controls were reset ($settingsFileName)');
        }
      case 'start_fullscreen' when b != null:
        s.startFullscreen = b;
      case 'remote_on_wifi' when b != null:
        s.remoteLan = b;
      case 'weather_mode' when v == 'web' || v == 'native':
        s.weatherMode = v;
      case 'volume_leveling' when levelingModes.contains(v):
        s.volumeLeveling = v;
      case 'picture' when pictureModes.contains(v):
        s.picture = v;
      case 'start_fullscreen' || 'remote_on_wifi' || 'weather_mode' || 'volume_leveling' || 'picture':
        ok = false;
      default:
        log('$settingsFileName: unknown key "$key" ignored');
        continue;
    }
    if (!ok) log('$settingsFileName: bad value "$value" for $key ignored');
  }
  return reset;
}

/// Startup: reads [f] if it exists, applies it to [s]. Returns true if parental controls were reset.
/// The caller then saves (which rewrites the file with defaults/current values and reset=false).
bool applySettingsFile(File f, Settings s, void Function(String) log) {
  try {
    if (!f.existsSync()) return false;
    return applySettingsText(f.readAsStringSync(), s, log);
  } on Object catch (e) {
    log('$settingsFileName could not be read: $e');
    return false;
  }
}

/// Writes [s] to [f] if the text changed. Never throws.
void writeSettingsFile(File f, Settings s, void Function(String) log) {
  try {
    final text = settingsFileText(s);
    if (f.existsSync() && f.readAsStringSync() == text) return;
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text, flush: true);
  } on Object catch (e) {
    log('$settingsFileName could not be written: $e');
  }
}

/// Menu "Open settings file" (Windows): the file in Notepad, created first if missing.
Future<void> openSettingsFile(File f, Settings s, void Function(String) log) async {
  if (!f.existsSync()) writeSettingsFile(f, s, log);
  try {
    await Process.start('notepad.exe', [f.path]);
  } on Object catch (e) {
    log('open ${f.path} failed: $e');
  }
}
