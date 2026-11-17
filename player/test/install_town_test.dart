import 'dart:io';

import 'package:archive_tv_player/settings/install_town.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('town');
    file = File('${dir.path}/town.txt');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  http.Client found() => MockClient((r) async => http.Response(
      '{"results":[{"name":"Oxford","admin1":"Mississippi","latitude":34.36,"longitude":-89.52}]}', 200));

  test('a typed town becomes the weather location and the file is removed', () async {
    file.writeAsStringSync('Oxford, MS');
    final s = Settings();
    expect(await applyInstallTown(file, s, found(), (_) {}), isTrue);
    expect(s.weatherPlace, 'Oxford, Mississippi');
    expect(s.weatherLat, 34.36);
    expect(file.existsSync(), isFalse);
  });

  test('no file = nothing to do; a town nobody knows keeps the default and drops the file', () async {
    final s = Settings();
    final before = s.weatherPlace;
    expect(await applyInstallTown(file, s, found(), (_) {}), isFalse);
    file.writeAsStringSync('Nowhereville');
    final none = MockClient((r) async => http.Response('{}', 200));
    expect(await applyInstallTown(file, s, none, (_) {}), isFalse);
    expect(s.weatherPlace, before);
    expect(file.existsSync(), isFalse);
  });

  test('offline keeps the file for the next launch', () async {
    file.writeAsStringSync('Oxford, MS');
    final down = MockClient((r) async => throw const SocketException('offline'));
    expect(await applyInstallTown(file, Settings(), down, (_) {}), isFalse);
    expect(file.existsSync(), isTrue);
  });
}
