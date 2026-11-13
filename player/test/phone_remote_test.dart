// Phone remote (QR): the LAN address picker, the QR token, the server over real HTTP, and the QR card.
// Every server here binds 127.0.0.1 (bindAddress): 0.0.0.0 would raise a Windows Firewall prompt for the test runner.
// Screenshots: $env:MENU_SHOTS='D:\...\_build\screens'; flutter test test/phone_remote_test.dart -> qr-*.png
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive_tv_player/remote/remote_server.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:archive_tv_player/ui/phone_remote_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  group('pickLanIp', () {
    test('a real adapter\'s private address beats VPN, VM, WSL and mobile-data adapters', () {
      expect(
          pickLanIp([
            ('vEthernet (WSL)', ['172.24.80.1']),
            ('VirtualBox Host-Only Network', ['192.168.56.1']),
            ('Tailscale', ['100.101.102.103']),
            ('Local Area Connection* 2', ['192.168.137.1']), // Windows mobile hotspot
            ('Wi-Fi', ['169.254.10.20', '10.0.0.37']),
          ]),
          '10.0.0.37');
      expect(pickLanIp([('rmnet_data0', ['10.120.4.5']), ('wlan0', ['192.168.1.175'])]), '192.168.1.175'); // Fire TV
      expect(pickLanIp([('tun0', ['10.8.0.2']), ('eth0', ['172.16.5.9'])]), '172.16.5.9');
    });

    test('192.168 first, then 10, then 172.16-31; list order breaks ties', () {
      expect(pickLanIp([('Ethernet', ['10.1.1.1']), ('Wi-Fi', ['192.168.0.9'])]), '192.168.0.9');
      expect(pickLanIp([('Ethernet', ['172.20.0.4', '10.1.1.1'])]), '10.1.1.1');
      expect(pickLanIp([('Ethernet', ['192.168.0.9']), ('Wi-Fi', ['192.168.1.9'])]), '192.168.0.9');
      expect(pickLanIp([('Ethernet', ['172.32.0.1', '172.15.0.1'])]), '172.32.0.1'); // neither is private: first one
    });

    test('falls back to a virtual adapter, then any address; never loopback or link-local; null when nothing', () {
      expect(pickLanIp([('vEthernet (Default Switch)', ['172.17.0.1']), ('Ethernet', ['8.8.4.4'])]), '172.17.0.1');
      expect(pickLanIp([('Ethernet', ['203.0.113.7'])]), '203.0.113.7');
      expect(pickLanIp([('Loopback Pseudo-Interface 1', ['127.0.0.1']), ('Wi-Fi', ['169.254.3.4'])]), isNull);
      expect(pickLanIp([]), isNull);
      expect(pickLanIp([('Wi-Fi', ['fe80::1'])]), isNull); // IPv6 only
    });

    test('isPrivateIp', () {
      for (final a in ['192.168.1.1', '10.0.0.1', '172.16.0.1', '172.31.255.1']) {
        expect(isPrivateIp(a), isTrue, reason: a);
      }
      for (final a in ['172.32.0.1', '100.64.0.1', '8.8.8.8', '127.0.0.1', '1.10.0.0']) {
        expect(isPrivateIp(a), isFalse, reason: a);
      }
    });
  });

  group('token', () {
    test('made with the PIN when LAN goes on, dropped when off, new on each turn-on; QR URL carries it', () {
      final s = Settings();
      final r = RemoteServer(s, windows: false)..lanIp = '192.168.1.175';
      expect(r.ensurePin(), isFalse);
      expect(s.remoteToken, isNull);
      s.remoteLan = true;
      expect(r.ensurePin(), isTrue);
      final first = s.remoteToken!;
      expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{16}$')));
      expect(s.remotePin, matches(RegExp(r'^\d{4}$')));
      expect(r.ensurePin(), isFalse);
      expect(r.phoneUrl, 'http://192.168.1.175:8765/remote?k=$first');
      expect(r.lanUrl, 'http://192.168.1.175:8765/remote');
      s.remoteLan = false;
      expect(r.ensurePin(), isTrue);
      expect(s.remoteToken, isNull);
      expect(r.phoneUrl, isNull);
      final pin = s.remotePin;
      s.remoteLan = true;
      r.ensurePin();
      expect(s.remoteToken, isNot(first));
      expect(s.remotePin, pin); // the typed PIN stays the same
      // Saved like the PIN (an app restart keeps a scanned phone connected).
      expect(Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>).remoteToken, s.remoteToken);
    });
  });

  group('server over real HTTP (Android TV mode)', () {
    late Settings settings;
    late RemoteServer server;
    late HttpClient http;
    final keys = <String>[], volumes = <int>[], channels = <int>[];
    var powers = 0;

    setUp(() async {
      HttpOverrides.global = null; // flutter_test fakes every HttpClient with 400s; this talks to a real server
      keys.clear();
      volumes.clear();
      channels.clear();
      powers = 0;
      settings = Settings()..remoteLan = true;
      server = RemoteServer(settings, windows: false)
        ..basePort = 18765
        ..bindAddress = ((_) => InternetAddress.loopbackIPv4)
        ..state = (() => {'channel': {'number': 4, 'name': 'Funnies'}, 'volume': 30, 'muted': false, 'mode': 'watch'})
        ..key = keys.add
        ..volume = volumes.add
        ..channel = channels.add
        ..power = () => powers++;
      server.ensurePin();
      await server.start();
      expect(server.lanListening, isTrue);
      http = HttpClient();
    });

    tearDown(() async {
      http.close(force: true);
      await server.stop();
    });

    Future<(int, String)> call(String method, String path, {String? key, Object? body, bool xRemote = true}) async {
      final req = await http.openUrl(method, Uri.parse('http://127.0.0.1:${server.port}$path'));
      if (key != null) req.headers.set('X-Pin', key);
      if (xRemote) req.headers.set('X-Remote', '1');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close();
      return (res.statusCode, await utf8.decodeStream(res));
    }

    test('the page is open; the API needs the token or the PIN (Android trusts nobody, not even loopback)', () async {
      final page = await call('GET', '/remote?k=${settings.remoteToken}');
      expect(page.$1, 200);
      expect(page.$2, contains("get('k')")); // the page keeps the QR key
      expect((await call('GET', '/api/state')).$1, 401);
      final s = await call('GET', '/api/state', key: settings.remoteToken);
      expect(s.$1, 200);
      expect((jsonDecode(s.$2) as Map)['channel'], {'number': 4, 'name': 'Funnies'});
      expect((jsonDecode(s.$2) as Map)['pinRequired'], isTrue);
      expect((await call('GET', '/api/state', key: settings.remotePin)).$1, 200);
    });

    test('keys, volume, channel and power work with the token', () async {
      final t = settings.remoteToken;
      expect((await call('POST', '/api/key', key: t, body: {'key': 'channelUp'})).$1, 200);
      expect((await call('POST', '/api/key', key: t, body: {'key': 'ok'})).$1, 200);
      expect((await call('POST', '/api/volume', key: t, body: {'level': 55})).$1, 200);
      expect((await call('POST', '/api/channel', key: t, body: {'number': 12})).$1, 200);
      expect((await call('POST', '/api/key', key: t, body: {'key': 'ok'}, xRemote: false)).$1, 403);
      expect((await call('POST', '/api/power', key: t, body: {})).$1, 200);
      expect([keys, volumes, channels, powers], [['channelUp', 'ok'], [55], [12], 1]);
    });

    test('wrong tokens are refused and 5 in a row lock the API for a minute', () async {
      final t = settings.remoteToken!;
      for (var i = 0; i < 5; i++) {
        expect((await call('POST', '/api/key', key: 'x$t', body: {'key': 'menu'})).$1, 401);
      }
      expect((await call('GET', '/api/state', key: t)).$1, 429);
      server.now = () => DateTime.now().add(const Duration(minutes: 2));
      expect((await call('GET', '/api/state', key: t)).$1, 200);
      expect(keys, isEmpty);
    });

    test('an old token stops working when the phone remote is turned off and on again', () async {
      final old = settings.remoteToken!;
      settings.remoteLan = false;
      server.ensurePin();
      await server.start(); // Android with LAN off: stopped
      expect(server.lanListening, isFalse);
      await expectLater(call('GET', '/api/state', key: old), throwsA(isA<SocketException>()));
      settings.remoteLan = true;
      server.ensurePin();
      await server.start();
      expect((await call('GET', '/api/state', key: old)).$1, 401);
      expect((await call('GET', '/api/state', key: settings.remoteToken)).$1, 200);
    });

    test('a foreign Host is refused even with the token', () async {
      final req = await http.openUrl('GET', Uri.parse('http://127.0.0.1:${server.port}/api/state'));
      req.headers
        ..set('X-Pin', settings.remoteToken!)
        ..host = 'evil.example';
      expect((await req.close()).statusCode, 403);
    });
  });

  test('Windows keeps trusting its own remote window (loopback) without a key', () async {
    final s = Settings()..remoteLan = true;
    final r = RemoteServer(s, windows: true)..state = (() => {'mode': 'watch'});
    r.ensurePin();
    final res = await r.handle('GET', '/api/state', {'host': '127.0.0.1:8765'}, '', loopback: true);
    expect(res.$1, 200);
    expect((jsonDecode(res.$3 as String) as Map)['pinRequired'], isFalse);
    expect((await r.handle('GET', '/api/state', {'host': '127.0.0.1:8765'}, '', loopback: true)).$1, 200);
    // Android hooks: no window there, and nothing touches user32.
    final a = RemoteServer(s, windows: false);
    expect(a.isWindowOpen(), isFalse);
    a.closeWindowOnExit();
  });

  testWidgets('menu: Remote > Phone remote (QR code) is reachable with the D-pad without a remote window (Fire TV)', (t) async {
    final calls = <String>[];
    t.view.physicalSize = const Size(1280, 960);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Material(
        child: MenuOverlay(
          settings: Settings(),
          current: null,
          onChanged: (_) {},
          onBlockCurrent: () {},
          onRefresh: () {},
          onClose: () {},
          onPhoneRemote: () => calls.add('qr'),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Remote  >'), findsOneWidget);
    await t.pump(); // the menu takes focus after its first frame
    String sel() => t.widget<Text>(find.descendant(of: find.byKey(MenuOverlay.selectedKey), matching: find.byType(Text))).data!;
    for (var i = 0; i < 10 && !sel().startsWith('Remote'); i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
    }
    expect(sel(), 'Remote  >');
    await t.sendKeyEvent(LogicalKeyboardKey.select); // Fire TV centre button
    await t.pump();
    expect(find.text('Remote window: OFF'), findsNothing); // Windows only
    expect(find.text('Remote on Wi-Fi: OFF'), findsOneWidget);
    expect(find.text('Phone remote (QR code)'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.select); // first row under Back
    expect(calls, ['qr']);
  });

  group('QR card', () {
    final out = Platform.environment['MENU_SHOTS'];
    const qr = 'http://192.168.1.175:8765/remote?k=Ab3dEf6hIj9lMn0p';

    setUpAll(() async {
      for (final f in [r'C:\Windows\Fonts\consola.ttf', r'C:\Windows\Fonts\consolab.ttf']) {
        if (File(f).existsSync()) {
          final loader = FontLoader('Consolas')..addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
          await loader.load();
        }
      }
    });

    Future<List<String>> pump(WidgetTester t, Size size, {bool on = true, String? qrUrl = qr, bool finding = false, GlobalKey? boundary}) async {
      final calls = <String>[];
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Material(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: 4 / 3, // inside the TV's 4:3 frame, as in the app
              child: RepaintBoundary(
                key: boundary,
                child: PhoneRemoteCard(
                  on: on,
                  qrUrl: qrUrl,
                  url: 'http://192.168.1.175:8765/remote',
                  pin: '4821',
                  finding: finding,
                  firewallNote: true,
                  onToggle: () => calls.add('toggle'),
                  onClose: () => calls.add('close'),
                ),
              ),
            ),
          ),
        ),
      ));
      await t.pump();
      return calls;
    }

    Future<void> shot(WidgetTester t, GlobalKey boundary, String name) async {
      if (out == null) return;
      await t.runAsync(() async {
        final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final png = await (await ro.toImage()).toByteData(format: ui.ImageByteFormat.png);
        File('$out${Platform.pathSeparator}qr-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    for (final (name, size) in [('small-640x480', const Size(640, 480)), ('tv-960x540', const Size(960, 540)), ('1080p', const Size(1920, 1080))]) {
      testWidgets('renders the QR, the address and the PIN at $name without overflow', (t) async {
        final b = GlobalKey();
        await pump(t, size, boundary: b);
        expect(t.takeException(), isNull);
        expect(find.text('http://192.168.1.175:8765/remote'), findsOneWidget);
        expect(find.text('PIN 4821'), findsOneWidget);
        expect(find.byType(QrImageView), findsOneWidget);
        expect(t.widget<QrImageView>(find.byType(QrImageView)).semanticsLabel, 'QR code: $qr');
        expect(QrValidator.validate(data: qr, errorCorrectionLevel: QrErrorCorrectLevel.M).status, QrValidationStatus.valid);
        // Big enough to scan across a room: at least 40% of the frame height, square, white quiet zone.
        final box = t.getRect(find.byKey(PhoneRemoteCard.qrKey));
        expect(box.width, box.height);
        expect(box.height, greaterThan(size.height * 0.4));
        await shot(t, b, name);
      });
    }

    testWidgets('OK toggles, Esc/Backspace/M close (Android Back is a route pop: TvScreen), arrows are swallowed, volume falls through', (t) async {
      final calls = await pump(t, const Size(960, 720));
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.sendKeyEvent(LogicalKeyboardKey.select);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.sendKeyEvent(LogicalKeyboardKey.backspace);
      await t.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(await t.sendKeyEvent(LogicalKeyboardKey.arrowUp), isTrue);
      expect(await t.sendKeyEvent(LogicalKeyboardKey.equal), isFalse);
      expect(calls, ['toggle', 'toggle', 'close', 'close', 'close']);
    });

    testWidgets('OFF, finding and no-address states show no QR', (t) async {
      final b = GlobalKey();
      await pump(t, const Size(960, 720), on: false, boundary: b);
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Press OK to turn it on.'), findsOneWidget);
      expect(find.text('OK: turn on    Back: close'), findsOneWidget);
      await shot(t, b, 'off');
      await pump(t, const Size(960, 720), qrUrl: null, finding: true);
      expect(find.textContaining('Finding'), findsOneWidget);
      await pump(t, const Size(960, 720), qrUrl: null, boundary: b);
      expect(find.textContaining('No network address found'), findsOneWidget);
      expect(find.byType(QrImageView), findsNothing);
      await shot(t, b, 'no-address');
    });
  });
}
