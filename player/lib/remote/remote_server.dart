import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../input/gamepad.dart';
import '../player/picture.dart';
import '../settings/settings_store.dart';
import 'remote_page.dart';
import 'remote_window.dart';

/// Remote button name -> the keyboard key it stands for. Remote presses go through the same
/// focus/key path as the keyboard (input/gamepad.dart dispatchKey), so the guide, menu and
/// On Demand screens all work from the remote with no remote-specific code.
final Map<String, LogicalKeyboardKey> remoteKeys = {
  'up': LogicalKeyboardKey.arrowUp,
  'down': LogicalKeyboardKey.arrowDown,
  'left': LogicalKeyboardKey.arrowLeft,
  'right': LogicalKeyboardKey.arrowRight,
  'ok': LogicalKeyboardKey.enter,
  'back': LogicalKeyboardKey.escape,
  'guide': LogicalKeyboardKey.keyG,
  'menu': LogicalKeyboardKey.keyM,
  'info': LogicalKeyboardKey.keyI,
  'favorite': LogicalKeyboardKey.keyF,
  'ondemand': LogicalKeyboardKey.keyO,
  'mute': LogicalKeyboardKey.keyU,
  'volUp': LogicalKeyboardKey.equal,
  'volDown': LogicalKeyboardKey.minus,
  'channelUp': LogicalKeyboardKey.pageUp,
  'channelDown': LogicalKeyboardKey.pageDown,
  'fullscreen': LogicalKeyboardKey.f11,
  'audioEarlier': LogicalKeyboardKey.bracketLeft,
  'audioLater': LogicalKeyboardKey.bracketRight,
  'audioReset': LogicalKeyboardKey.backslash,
  'sleep': LogicalKeyboardKey.keyT,
  'last': LogicalKeyboardKey.keyL,
  for (var d = 0; d <= 9; d++) '$d': LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d),
};

/// A press of [k]: key down then up, delivered like a real key.
void pressKey(LogicalKeyboardKey k) {
  dispatchKey(keyEvent(k, down: true));
  dispatchKey(keyEvent(k, down: false));
}

typedef Reply = (int status, String type, Object body);

/// Tiny HTTP server for the remote window (Windows) and the phone remote (Windows and Android TV / Fire TV).
/// Windows binds 127.0.0.1, or every interface when [Settings.remoteLan] is on; Android only runs while
/// it is on (no remote window there). LAN requests then need the PIN or the QR code's token. The TV screen
/// fills in [state], [volume] and [channel]; [key] defaults to pressing the matching keyboard key.
class RemoteServer {
  static const firstPort = 8765;

  final Settings settings;
  final void Function(String) log;

  /// Windows: the Edge remote window and the loopback server for it exist. False on Android TV.
  final bool windows;
  Map<String, Object?> Function() state = () => {};
  void Function(String key) key = (k) => pressKey(remoteKeys[k]!);
  void Function(int level) volume = (_) {};
  void Function(int number) channel = (_) {};

  /// POST /api/power: quit the whole app (main.dart: the same clean path as the window's close button).
  void Function() power = () {};

  /// A checked POST /api/setting: captionsOn (bool), captionSize (int 1-7), leveling, weatherMode, picture.
  void Function(String name, Object value) setting = (_, _) {};
  /// POST /api/parental {pin}: answers the TV's parental PIN prompt (state "pinPrompt").
  void Function(String pin) parentalPin = (_) {};
  Future<List<int>?> Function(int number) logo = (_) async => null;

  RemoteServer(this.settings, {void Function(String)? log, bool? windows})
      : log = log ?? ((_) {}),
        windows = windows ?? Platform.isWindows {
    if (this.windows) {
      launchWindow = openWindow;
    } else {
      isWindowOpen = () => false; // no user32 on Android
      closeWindow = () {};
    }
  }

  HttpServer? _server;
  /// The first port tried ([firstPort]; tests use their own range so they never meet a running app).
  int basePort = firstPort;
  int port = firstPort;
  bool _boundLan = false;

  /// Listening for phones right now (LAN on and bound); [failed]: the last start found no free port.
  bool get lanListening => _server != null && _boundLan;
  bool failed = false;

  /// This device's LAN address (null until found or if there is none); [findingIp] while it is looked up.
  String? lanIp;
  bool findingIp = false;
  String? get lanUrl => lanIp == null ? null : 'http://$lanIp:$port/remote';
  String get localUrl => 'http://127.0.0.1:$port/remote';

  /// The QR code's address: [lanUrl] with the token, so a scan connects without typing the PIN.
  String? get phoneUrl {
    final u = lanUrl, t = settings.remoteToken;
    return u == null || t == null ? null : '$u?k=$t';
  }

  /// Looks the LAN address up again (the QR card does on open: DHCP may have moved it). The server is
  /// bound to every interface, so no re-bind is needed.
  Future<void> refreshLanIp() async {
    findingIp = true;
    try {
      lanIp = await findLanIp();
    } finally {
      findingIp = false;
    }
  }

  // Wrong-PIN lockout (LAN only): 5 misses in a row lock LAN requests out for a minute.
  int _misses = 0;
  DateTime _lockedUntil = DateTime(0);
  DateTime Function() now = DateTime.now;

  /// Makes sure a LAN PIN and QR token exist while LAN is on; turning LAN off drops the token, so each
  /// turn-on gets a new one (old QR codes stop working). Returns true if settings changed (caller saves).
  bool ensurePin() {
    if (!settings.remoteLan) {
      if (settings.remoteToken == null) return false;
      settings.remoteToken = null;
      return true;
    }
    if (settings.remotePin != null && settings.remoteToken != null) return false;
    final r = Random.secure();
    settings.remotePin ??= r.nextInt(10000).toString().padLeft(4, '0');
    settings.remoteToken ??= base64Url.encode(List.generate(12, (_) => r.nextInt(256))); // 96 bits, 16 chars
    return true;
  }

  Future<void> _busy = Future.value();

  /// Starts, or re-binds after the LAN setting changed (calls run one at a time).
  /// Tries [firstPort] then the next 9 ports. Android with LAN off: stops instead (nothing to serve).
  Future<void> start() => _busy = _busy.then((_) => _start()).catchError((Object e) => log('remote: start failed: $e'));

  Future<void> _start() async {
    final lan = settings.remoteLan;
    if (!lan && !windows) return _stop();
    if (_server != null && lan == _boundLan) return;
    final keepPort = _server != null;
    await _server?.close(force: true);
    _server = null;
    if (lan) await refreshLanIp();
    for (var p = keepPort ? port : basePort; p < basePort + 10; p++) {
      try {
        final at = bindAddress(lan);
        _server = await HttpServer.bind(at, p);
        port = p;
        _boundLan = lan;
        log('remote: listening on ${at.address}:$p');
        _server!.listen(_serve, onError: (Object e) => log('remote: $e'));
        failed = false;
        return;
      } on SocketException {
        continue; // busy: try the next one
      }
    }
    failed = true;
    log('remote: no free port in $basePort-${basePort + 9}');
  }

  /// Opens the remote window beside the TV window (or brings it forward).
  Future<void> openWindow() async {
    try {
      await openRemoteWindow(localUrl, log: log);
    } on Object catch (e) {
      log('remote: could not open a window: $e');
    }
  }

  /// Every IPv4 interface while LAN is on (phones; [_serve] still refuses non-private callers), else loopback.
  /// Tests bind loopback only: binding 0.0.0.0 would raise a Windows Firewall prompt for the test runner.
  InternetAddress Function(bool lan) bindAddress = (lan) => lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;

  /// Window hooks, replaceable in tests.
  bool Function() isWindowOpen = remoteWindowOpen;
  void Function() closeWindow = closeRemoteWindow;
  Future<void> Function() launchWindow = () async {};

  /// R key, menu item and the REMOTE corner button: opens the window if it is closed, else closes it.
  /// Returns whether it is now open.
  Future<bool> toggleWindow() async {
    if (isWindowOpen()) {
      closeWindow();
      log('remote: window closed');
      return false;
    }
    await launchWindow();
    return true;
  }

  /// App shutdown: the remote window goes with the TV.
  void closeWindowOnExit() {
    if (!isWindowOpen()) return;
    closeWindow();
    log('remote: window closed with the app');
  }

  /// Closes the server (app exit, Android going to the background); [start] brings it back.
  Future<void> stop() => _busy = _busy.then((_) => _stop()).catchError((Object e) => log('remote: stop failed: $e'));

  Future<void> _stop() async {
    final s = _server;
    if (s == null) return;
    _server = null;
    await s.close(force: true);
    log('remote: stopped');
  }

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    final from = req.connectionInfo?.remoteAddress;
    // LAN only: loopback or a private-range caller (home network); anything else (public, VPN/CGNAT) is refused.
    if (from == null || !(from.isLoopback || isPrivateIp(from.address))) {
      res.statusCode = 403;
      await res.close().catchError((_) {});
      return;
    }
    try {
      final body = req.method == 'POST' ? await utf8.decodeStream(req).timeout(const Duration(seconds: 5)) : '';
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      final (status, type, out) = await handle(req.method, req.uri.path, headers, body,
          loopback: from.isLoopback);
      res
        ..statusCode = status
        ..headers.set('Content-Type', type)
        ..headers.set('Cache-Control', 'no-store')
        ..headers.set('X-Content-Type-Options', 'nosniff');
      if (out is List<int>) {
        res.add(out);
      } else {
        res.write(out);
      }
    } on Object catch (e) {
      log('remote: request failed: $e');
      res.statusCode = 500;
    }
    await res.close().catchError((_) {});
  }

  Reply _json(Object o, [int status = 200]) => (status, 'application/json; charset=utf-8', jsonEncode(o));
  Reply _err(int status, String why) => _json({'error': why}, status);

  bool _hostOk(String? hostPort) {
    if (hostPort == null) return false;
    final u = Uri.tryParse('http://$hostPort');
    if (u == null || u.port != port) return false;
    return u.host == '127.0.0.1' || u.host == 'localhost' || (settings.remoteLan && u.host == lanIp);
  }

  /// Routes one request. Pure apart from the callbacks, so tests call it directly.
  /// [headers] has lower-case names; [loopback] is true for requests from this device. Only the Windows PC
  /// trusts loopback (its remote window); on Android any other app could reach 127.0.0.1, so it needs the key too.
  Future<Reply> handle(String method, String path, Map<String, String> headers, String body, {required bool loopback}) async {
    // Host and Origin must name this server (stops DNS rebinding and cross-site pages).
    if (!_hostOk(headers['host'])) return _err(403, 'bad host');
    final origin = headers['origin'];
    if (origin != null && !_hostOk(Uri.tryParse(origin)?.authority)) return _err(403, 'bad origin');
    final trusted = loopback && windows;
    if (!trusted) {
      if (!settings.remoteLan) return _err(403, 'lan off');
      if (path.startsWith('/api/')) {
        if (now().isBefore(_lockedUntil)) return _err(429, 'locked');
        // X-Pin carries the typed PIN or the QR code's token (the page sends whichever it has).
        final key = headers['x-pin'];
        if (key == null || (key != settings.remotePin && key != settings.remoteToken)) {
          if (++_misses >= 5) {
            _misses = 0;
            _lockedUntil = now().add(const Duration(minutes: 1));
            log('remote: 5 wrong PINs, LAN locked for a minute');
          }
          return _err(401, 'pin');
        }
        _misses = 0;
      }
    }
    if (method == 'GET') {
      if (path == '/' || path == '/remote') return (200, 'text/html; charset=utf-8', remotePage);
      if (path == '/api/state') return _json({...state(), 'pinRequired': !trusted});
      final m = RegExp(r'^/logo/(\d+)\.png$').firstMatch(path);
      if (m != null) {
        final bytes = await logo(int.parse(m[1]!));
        return bytes == null ? _err(404, 'no logo') : (200, 'image/png', bytes);
      }
      return _err(404, 'not found');
    }
    if (method != 'POST') return _err(405, 'method');
    // A custom header can't be sent cross-site without a CORS preflight, which this server never allows.
    if (headers['x-remote'] != '1') return _err(403, 'x-remote header required');
    final Object? j;
    try {
      j = body.isEmpty ? const <String, Object?>{} : jsonDecode(body);
    } on FormatException {
      return _err(400, 'bad json');
    }
    if (j is! Map) return _err(400, 'bad json');
    switch (path) {
      case '/api/key':
        final k = j['key'];
        if (k is! String || !remoteKeys.containsKey(k)) return _err(400, 'unknown key');
        key(k);
      case '/api/volume':
        final l = j['level'];
        if (l is! num) return _err(400, 'level');
        volume(l.round().clamp(0, 100));
      case '/api/channel':
        final n = j['number'];
        if (n is! int) return _err(400, 'number');
        channel(n);
      case '/api/parental':
        final pin = j['pin'];
        if (pin is! String || !RegExp(r'^\d{4}$').hasMatch(pin)) return _err(400, 'pin');
        parentalPin(pin); // never logged
      case '/api/power':
        log('remote: power');
        power();
      case '/api/setting':
        final v = settingValue(j['name'], j['value']);
        if (v == null) return _err(400, 'setting');
        setting(j['name'] as String, v);
      default:
        return _err(404, 'not found');
    }
    return _json({'ok': true});
  }

  /// The value to apply for a remote settings-panel change, or null if [name]/[value] isn't allowed.
  /// Remote on Wi-Fi is deliberately not settable from the remote (it only shows its status).
  static Object? settingValue(Object? name, Object? value) => switch (name) {
        'captionsOn' when value is bool => value,
        'captionSize' when value is int => value.clamp(1, 7),
        'leveling' when levelingModes.contains(value) => value,
        'weatherMode' when value == 'web' || value == 'native' => value,
        'picture' when pictureModes.contains(value) => value,
        _ => null,
      };

  /// This device's LAN IPv4 address (see [pickLanIp]); null if there is none or the list fails.
  static Future<String?> findLanIp() async {
    try {
      return pickLanIp([
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) (i.name, [for (final a in i.addresses) a.address]),
      ]);
    } on Object {
      return null;
    }
  }
}

/// An RFC 1918 home-network IPv4 address: 192.168/16, 10/8 or 172.16/12.
bool isPrivateIp(String a) => a.startsWith('192.168.') || a.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);

/// Adapter names that are never the home network: VMs, WSL/Docker bridges, VPNs, mobile data, Wi-Fi Direct.
final _virtual = RegExp(
    r'vethernet|virtualbox|vmware|vmnet|hyper-v|docker|wsl|^veth|^br-|^virbr|tailscale|zerotier|hamachi|wireguard|^wg\d|'
    r'nordlynx|openvpn|^tun|^tap|utun|^ppp|vpn|^rmnet|^ccmni|^p2p|^ap\d|^dummy|loopback|bluetooth|local area connection\*',
    caseSensitive: false);

/// Picks the phone-reachable IPv4 address from (interface name, addresses) pairs: private ranges on a real
/// adapter first (192.168, then 10, then 172.16-31), then private ones on a virtual/VPN adapter, then any
/// other address; never loopback or link-local (169.254). Ties keep the list order. Null if nothing is left.
String? pickLanIp(List<(String, List<String>)> interfaces) {
  int rank(String name, String a) {
    final private = !isPrivateIp(a)
        ? null
        : a.startsWith('192.168.')
            ? 0
            : a.startsWith('10.')
                ? 1
                : 2;
    final virtual = _virtual.hasMatch(name);
    return private == null ? (virtual ? 7 : 6) : private + (virtual ? 3 : 0);
  }

  String? best;
  var bestRank = 99;
  for (final (name, addrs) in interfaces) {
    for (final a in addrs) {
      if (!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(a) || a.startsWith('127.') || a.startsWith('169.254.')) continue;
      final r = rank(name, a);
      if (r < bestRank) (best, bestRank) = (a, r);
    }
  }
  return best;
}
