import 'dart:convert';

import 'package:archive_tv_player/remote/remote_server.dart';
import 'package:archive_tv_player/remote/remote_window.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Settings settings;
  late RemoteServer server;
  late List<String> keys;
  late List<int> volumes, channels;
  late List<(String, Object)> sets;

  setUp(() {
    settings = Settings();
    keys = [];
    volumes = [];
    channels = [];
    sets = [];
    server = RemoteServer(settings)
      ..setting = ((n, v) => sets.add((n, v)))
      ..state = (() => {'channel': {'number': 4, 'name': 'Funnies'}, 'volume': 80, 'muted': false, 'mode': 'watch'})
      ..key = keys.add
      ..volume = volumes.add
      ..channel = channels.add;
  });

  const local = {'host': '127.0.0.1:8765'};
  const post = {'host': '127.0.0.1:8765', 'x-remote': '1'};

  Future<(int, String, Object)> call(String method, String path,
          {Map<String, String> headers = post, Object? body, bool loopback = true}) =>
      server.handle(method, path, headers, body == null ? '' : jsonEncode(body), loopback: loopback);

  test('remote window goes right of the TV, else left, else inside the work area, never off-screen', () {
    const work = (left: -1920, top: 0, right: 0, bottom: 1040); // a monitor left of the primary
    Box tv(int l, int t, int r, int b) => (left: l, top: t, right: r, bottom: b);
    expect(placeRemote(tv(-1900, 100, -1000, 700), work, 260, 440), (left: -992, top: 100, right: -732, bottom: 540));
    expect(placeRemote(tv(-1000, 100, -100, 700), work, 260, 440), (left: -1268, top: 100, right: -1008, bottom: 540));
    expect(placeRemote(tv(-1920, 800, 0, 1040), work, 260, 440), (left: -260, top: 600, right: 0, bottom: 1040)); // fullscreen TV
    expect(placeRemote(tv(0, -50, 100, 100), (left: 0, top: 0, right: 200, bottom: 300), 260, 440),
        (left: 0, top: 0, right: 200, bottom: 300)); // shrunk to a tiny work area
  });

  test('GET /remote serves the page; /api/state is the screen state as JSON', () async {
    final page = await call('GET', '/remote', headers: local);
    expect(page.$1, 200);
    expect(page.$2, startsWith('text/html'));
    expect(page.$3 as String, contains('Archive TV Remote'));
    final s = await call('GET', '/api/state', headers: local);
    expect(s.$1, 200);
    final j = jsonDecode(s.$3 as String) as Map;
    expect(j['channel'], {'number': 4, 'name': 'Funnies'});
    expect(j['volume'], 80);
    expect(j['pinRequired'], isFalse);
  });

  test('every remote key maps to a keyboard key; unknown keys are refused', () async {
    expect(remoteKeys['mute'], LogicalKeyboardKey.keyU);
    expect(remoteKeys['volUp'], LogicalKeyboardKey.equal);
    expect(remoteKeys['channelDown'], LogicalKeyboardKey.pageDown);
    expect(remoteKeys['7'], LogicalKeyboardKey.digit7);
    expect((await call('POST', '/api/key', body: {'key': 'guide'})).$1, 200);
    expect((await call('POST', '/api/key', body: {'key': 'launchMissiles'})).$1, 400);
    expect(keys, ['guide']);
  });

  test('volume is clamped to 0-100; channel needs an int', () async {
    await call('POST', '/api/volume', body: {'level': 140});
    await call('POST', '/api/volume', body: {'level': -3});
    await call('POST', '/api/volume', body: {'level': 42.6});
    expect(volumes, [100, 0, 43]);
    expect((await call('POST', '/api/volume', body: {'level': 'loud'})).$1, 400);
    expect((await call('POST', '/api/channel', body: {'number': 12})).$1, 200);
    expect((await call('POST', '/api/channel', body: {'number': '12'})).$1, 400);
    expect(channels, [12]);
  });

  test('POST /api/setting: checked names and values only; Wi-Fi is not settable from the remote', () async {
    expect((await call('POST', '/api/setting', body: {'name': 'captionsOn', 'value': true})).$1, 200);
    expect((await call('POST', '/api/setting', body: {'name': 'captionSize', 'value': 9})).$1, 200);
    expect((await call('POST', '/api/setting', body: {'name': 'leveling', 'value': 'strong'})).$1, 200);
    expect((await call('POST', '/api/setting', body: {'name': 'weatherMode', 'value': 'native'})).$1, 200);
    for (final bad in [
      {'name': 'captionsOn', 'value': 'yes'},
      {'name': 'captionSize', 'value': 2.5},
      {'name': 'leveling', 'value': 'max'},
      {'name': 'weatherMode', 'value': 'radar'},
      {'name': 'remoteLan', 'value': true},
      {'name': 'volume', 'value': 10},
      {'value': true},
    ]) {
      expect((await call('POST', '/api/setting', body: bad)).$1, 400, reason: '$bad');
    }
    expect(sets, [('captionsOn', true), ('captionSize', 7), ('leveling', 'strong'), ('weatherMode', 'native')]);
    // Same rules as the other POSTs.
    const on = {'name': 'captionsOn', 'value': true};
    expect((await call('POST', '/api/setting', headers: local, body: on)).$1, 403);
    expect((await call('POST', '/api/setting', headers: {...post, 'origin': 'http://evil.example'}, body: on)).$1, 403);
    settings.remoteLan = true;
    server.ensurePin();
    server.lanIp = '192.168.1.50';
    const lan = {'host': '192.168.1.50:8765', 'x-remote': '1'};
    const off = {'name': 'captionsOn', 'value': false};
    expect((await call('POST', '/api/setting', headers: lan, body: off, loopback: false)).$1, 401);
    expect((await call('POST', '/api/setting', headers: {...lan, 'x-pin': settings.remotePin!}, body: off, loopback: false)).$1, 200);
    expect(sets.last, ('captionsOn', false));
  });

  test('the page has the CC button and a settings view with every control, and no REMOTE toggle', () async {
    final page = (await call('GET', '/remote', headers: local)).$3 as String;
    for (final id in ['ccBtn', 'settings', 'setCaptions', 'sizeDown', 'sizeUp', 'sizeLevel', 'sample', 'setLeveling', 'setWeather', 'wifi']) {
      expect(page, contains('id="$id"'), reason: id);
    }
    expect(page, contains("'/api/setting'"));
    expect(page, isNot(contains('data-key="remote"')));
    // The settings view lives inside the now-playing window (no new rows, so the remote keeps its size).
    final lcd = page.indexOf('<div class="lcd"');
    expect(lcd, greaterThan(0));
    expect(page.indexOf('id="settings"'), greaterThan(lcd));
    expect(page.indexOf('id="settings"'), lessThan(page.indexOf('class="grid g4 hide-set"')));
  });

  test('POSTs need X-Remote; foreign Host or Origin is rejected', () async {
    expect((await call('POST', '/api/key', headers: local, body: {'key': 'ok'})).$1, 403);
    expect((await call('GET', '/api/state', headers: {'host': 'evil.example:8765'})).$1, 403);
    expect((await call('GET', '/api/state', headers: {'host': '127.0.0.1:9999'})).$1, 403);
    expect((await call('POST', '/api/key', headers: {...post, 'origin': 'http://evil.example'}, body: {'key': 'ok'})).$1, 403);
    expect((await call('POST', '/api/key', headers: {...post, 'origin': 'http://localhost:8765'}, body: {'key': 'ok'})).$1, 200);
    expect(keys, ['ok']);
  });

  test('LAN: refused while off; with it on the PIN is required and wrong PINs lock out', () async {
    expect((await call('GET', '/remote', headers: local, loopback: false)).$1, 403);
    settings.remoteLan = true;
    expect(server.ensurePin(), isTrue);
    expect(settings.remotePin, matches(RegExp(r'^\d{4}$')));
    expect(server.ensurePin(), isFalse); // made once
    server.lanIp = '192.168.1.50';
    const lan = {'host': '192.168.1.50:8765', 'x-remote': '1'};
    expect((await call('GET', '/remote', headers: lan, loopback: false)).$1, 200); // the page itself is open
    expect((await call('GET', '/api/state', headers: lan, loopback: false)).$1, 401);
    final ok = {...lan, 'x-pin': settings.remotePin!};
    expect((await call('POST', '/api/key', headers: ok, body: {'key': 'menu'}, loopback: false)).$1, 200);
    expect(jsonDecode((await call('GET', '/api/state', headers: ok, loopback: false)).$3 as String)['pinRequired'], isTrue);
    final wrong = {...lan, 'x-pin': settings.remotePin == '0000' ? '1111' : '0000'};
    for (var i = 0; i < 5; i++) {
      await call('GET', '/api/state', headers: wrong, loopback: false);
    }
    expect((await call('GET', '/api/state', headers: ok, loopback: false)).$1, 429); // locked even with the right PIN
    expect((await call('GET', '/api/state', headers: local)).$1, 200); // this PC never needs the PIN
    expect(keys, ['menu']);
  });

  test('toggleWindow opens when closed, closes when open (also after the user closed it)', () async {
    var open = false;
    final calls = <String>[];
    server
      ..isWindowOpen = (() => open)
      ..launchWindow = () async {
        calls.add('launch');
        open = true;
      }
      ..closeWindow = () {
        calls.add('close');
        open = false;
      };
    expect(await server.toggleWindow(), isTrue);
    expect(await server.toggleWindow(), isFalse);
    expect(await server.toggleWindow(), isTrue);
    open = false; // closed with its own X
    expect(await server.toggleWindow(), isTrue);
    expect(calls, ['launch', 'close', 'launch', 'launch']);
  });

  test('app shutdown closes an open remote window, and leaves a closed one alone', () {
    var open = true, closes = 0;
    server
      ..isWindowOpen = (() => open)
      ..closeWindow = () {
        closes++;
        open = false;
      };
    server.closeWindowOnExit();
    expect((open, closes), (false, 1));
    server.closeWindowOnExit();
    expect(closes, 1);
  });
}
