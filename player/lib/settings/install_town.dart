import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../weather/weather.dart';
import 'settings_store.dart';

/// The Windows installer's "Your town" page leaves the typed town in `town.txt` beside the exe. On the next launch
/// it becomes the weather location (looked up once), then the file is removed. A lookup that finds nothing drops
/// the file (the default stays; the menu can change it); a network failure keeps it for the next launch.
/// Returns true when [s] changed and should be saved.
Future<bool> applyInstallTown(File townFile, Settings s, http.Client client, void Function(String) log) async {
  if (!townFile.existsSync()) return false;
  final town = utf8.decode(townFile.readAsBytesSync(), allowMalformed: true).trim();
  if (town.isEmpty) {
    townFile.deleteSync();
    return false;
  }
  try {
    final p = await geocode(client, town).timeout(const Duration(seconds: 8));
    townFile.deleteSync();
    if (p == null) {
      log('install town "$town": not found, weather stays at ${s.weatherPlace}');
      return false;
    }
    s
      ..weatherPlace = p.name
      ..weatherLat = p.lat
      ..weatherLon = p.lon;
    log('weather location from the installer: ${p.name}');
    return true;
  } on Object catch (e) {
    log('install town "$town": lookup failed ($e), will retry next launch');
    return false;
  }
}
