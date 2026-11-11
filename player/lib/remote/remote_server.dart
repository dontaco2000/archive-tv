import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../input/gamepad.dart';
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
  for (var d = 0; d <= 9; d++) '$d': LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d),
};

/// A press of [k]: key down then up, delivered like a real key.
void pressKey(LogicalKeyboardKey k) {
  dispatchKey(keyEvent(k, down: true));
  dispatchKey(keyEvent(k, down: false));
}

typedef Reply = (int status, String type, Object body);

/// Tiny HTTP server for the remote window (Windows only). Binds 127.0.0.1, or every interface when
/// [Settings.remoteLan] is on; LAN requests then need the PIN. The TV screen fills in [state],
/// [volume] and [channel]; [key] defaults to pressing the matching keyboard key.
class RemoteServer {
  static const firstPort = 8765;

  final Settings settings;
  final void Function(String) log;
  Map<String, Object?> Function() state = () => {};
  void Function(String key) key = (k) => pressKey(remoteKeys[k]!);
  void Function(int level) volume = (_) {};
  void Function(int number) channel = (_) {};
  Future<List<int>?> Function(int number) logo = (_) async => null;

  RemoteServer(this.settings, {void Function(String)? log}) : log = log ?? ((_) {});

  HttpServer? _server;
  int port = firstPort;
  bool _boundLan = false;

  /// This PC's LAN address (null until found or if there is none).
  String? lanIp;
  String? get lanUrl => lanIp == null ? null : 'http://$lanIp:$port/remote';
  String get localUrl => 'http://127.0.0.1:$port/remote';

  // Wrong-PIN lockout (LAN only): 5 misses in a row lock LAN requests out for a minute.
  int _misses = 0;
  DateTime _lockedUntil = DateTime(0);
  DateTime Function() now = DateTime.now;

  /// Makes sure a LAN PIN exists when LAN is on. Returns true if settings changed (caller saves).
  bool ensurePin() {
    if (!settings.remoteLan || settings.remotePin != null) return false;
    settings.remotePin = Random.secure().nextInt(10000).toString().padLeft(4, '0');
    return true;
  }

  Future<void> _busy = Future.value();

  /// Starts, or re-binds after the LAN setting changed (calls run one at a time).
  /// Tries [firstPort] then the next 9 ports.
  Future<void> start() => _busy = _busy.then((_) => _start()).catchError((Object e) => log('remote: start failed: $e'));

  Future<void> _start() async {
    final lan = settings.remoteLan;
    if (_server != null && lan == _boundLan) return;
    final keepPort = _server != null;
    await _server?.close(force: true);
    _server = null;
    if (lan) lanIp ??= await findLanIp();
    for (var p = keepPort ? port : firstPort; p < firstPort + 10; p++) {
      try {
        _server = await HttpServer.bind(lan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4, p);
        port = p;
        _boundLan = lan;
        log('remote: listening on ${lan ? '0.0.0.0' : '127.0.0.1'}:$p');
        _server!.listen(_serve, onError: (Object e) => log('remote: $e'));
        return;
      } on SocketException {
        continue; // busy: try the next one
      }
    }
    log('remote: no free port in $firstPort-${firstPort + 9}');
  }

  /// Opens the remote window beside the TV window (or brings it forward).
  Future<void> openWindow() async {
    try {
      await openRemoteWindow(localUrl, log: log);
    } on Object catch (e) {
      log('remote: could not open a window: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    try {
      final body = req.method == 'POST' ? await utf8.decodeStream(req).timeout(const Duration(seconds: 5)) : '';
      final headers = <String, String>{};
      req.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      final (status, type, out) = await handle(req.method, req.uri.path, headers, body,
          loopback: req.connectionInfo?.remoteAddress.isLoopback ?? false);
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
  /// [headers] has lower-case names; [loopback] is true for requests from this PC.
  Future<Reply> handle(String method, String path, Map<String, String> headers, String body, {required bool loopback}) async {
    // Host and Origin must name this server (stops DNS rebinding and cross-site pages).
    if (!_hostOk(headers['host'])) return _err(403, 'bad host');
    final origin = headers['origin'];
    if (origin != null && !_hostOk(Uri.tryParse(origin)?.authority)) return _err(403, 'bad origin');
    if (!loopback) {
      if (!settings.remoteLan) return _err(403, 'lan off');
      if (path.startsWith('/api/')) {
        if (now().isBefore(_lockedUntil)) return _err(429, 'locked');
        if (headers['x-pin'] != settings.remotePin || settings.remotePin == null) {
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
      if (path == '/api/state') return _json({...state(), 'pinRequired': !loopback});
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
      default:
        return _err(404, 'not found');
    }
    return _json({'ok': true});
  }

  /// First private IPv4 address of this PC (192.168/10/172.16-31), else any non-loopback one.
  static Future<String?> findLanIp() async {
    try {
      final addrs = [
        for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4))
          for (final a in i.addresses)
            if (!a.isLoopback && !a.isLinkLocal) a.address,
      ];
      bool private(String a) =>
          a.startsWith('192.168.') || a.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a);
      return addrs.where(private).firstOrNull ?? addrs.firstOrNull;
    } on Object {
      return null;
    }
  }
}
