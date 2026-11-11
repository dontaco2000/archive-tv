import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Remote window size in logical pixels (scaled by the TV monitor's DPI).
const remoteWidth = 260, remoteHeight = 370;
const _title = 'Archive TV Remote'; // the page's <title>, which Edge uses as the window title

typedef Box = ({int left, int top, int right, int bottom});

/// Where the remote goes: right of the TV window if it fits in [work], else left of it, else inside
/// [work] at the right edge. Always fully inside [work] (shrunk if [work] is smaller).
Box placeRemote(Box tv, Box work, int w, int h) {
  w = w.clamp(1, work.right - work.left);
  h = h.clamp(1, work.bottom - work.top);
  const gap = 8;
  final int x;
  if (tv.right + gap + w <= work.right) {
    x = tv.right + gap;
  } else if (tv.left - gap - w >= work.left) {
    x = tv.left - gap - w;
  } else {
    x = work.right - w;
  }
  final y = tv.top.clamp(work.top, work.bottom - h);
  return (left: x, top: y, right: x + w, bottom: y + h);
}

/// Opens the remote as its own small window beside the TV (Edge or Chrome app mode, in their own
/// profile), or brings an open one to the front. Falls back to the default browser.
Future<void> openRemoteWindow(String url, {void Function(String)? log}) async {
  final u = _User32();
  final existing = u.find(_title);
  var spot = u.spotBesideTv();
  for (var i = 0; spot == null && i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100)); // --remote at startup: the TV window may not be up yet
    spot = u.spotBesideTv();
  }
  if (existing != 0) {
    if (spot != null) u.move(existing, spot);
    u.front(existing);
    return;
  }
  final local = Platform.environment['LOCALAPPDATA'];
  final args = [
    '--app=$url',
    if (spot != null) ...['--window-size=${spot.right - spot.left},${spot.bottom - spot.top}', '--window-position=${spot.left},${spot.top}'],
    // Own profile: a separate browser process, so the flags apply even when the user's browser is open.
    if (local != null) ...['--user-data-dir=$local\\ArchiveTV\\remote-window', '--no-first-run', '--no-default-browser-check'],
  ];
  for (final exe in _browserPaths()) {
    if (!File(exe).existsSync()) continue;
    try {
      await Process.start(exe, args, mode: ProcessStartMode.detached);
      log?.call('remote: opened with $exe');
      // The browser may ignore or rescale the flags: move the window once it shows up.
      if (spot != null) {
        // Edge may also restore a remembered placement just after showing it, so keep the spot for 3 s.
        var settled = 0;
        for (var i = 0; i < 110 && settled < 30; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final h = u.find(_title);
          if (h == 0) continue;
          settled++;
          if (u.rect(h) != spot) u.move(h, spot);
        }
        log?.call('remote: window at $spot');
      }
      return;
    } on Object catch (e) {
      log?.call('remote: $exe failed: $e');
    }
  }
  await Process.start('explorer.exe', [url], mode: ProcessStartMode.detached); // default browser
  log?.call('remote: opened in the default browser');
}

List<String> _browserPaths() {
  final env = Platform.environment;
  final bases = [env['ProgramFiles(x86)'], env['ProgramFiles'], env['LOCALAPPDATA']].whereType<String>();
  return [
    for (final b in bases) '$b\\Microsoft\\Edge\\Application\\msedge.exe',
    for (final b in bases) '$b\\Google\\Chrome\\Application\\chrome.exe',
  ];
}

/// The few user32 calls needed, in physical pixels.
class _User32 {
  final _d = DynamicLibrary.open('user32.dll');
  late final _findWindow =
      _d.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>), int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
  late final _getWindowRect = _d.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('GetWindowRect');
  late final _monitorFromWindow = _d.lookupFunction<IntPtr Function(IntPtr, Uint32), int Function(int, int)>('MonitorFromWindow');
  late final _getMonitorInfo = _d.lookupFunction<Int32 Function(IntPtr, Pointer<Int32>), int Function(int, Pointer<Int32>)>('GetMonitorInfoW');
  late final _getDpiForWindow = _d.lookupFunction<Uint32 Function(IntPtr), int Function(int)>('GetDpiForWindow');
  late final _setWindowPos = _d.lookupFunction<Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
      int Function(int, int, int, int, int, int, int)>('SetWindowPos');
  late final _showWindow = _d.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
  late final _isVisible = _d.lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');
  late final _setForeground = _d.lookupFunction<Int32 Function(IntPtr), int Function(int)>('SetForegroundWindow');

  int find(String title, [String? cls]) {
    final t = title.toNativeUtf16(), c = cls?.toNativeUtf16() ?? nullptr;
    try {
      return _findWindow(c.cast(), t);
    } finally {
      calloc.free(t);
      if (c != nullptr) calloc.free(c);
    }
  }

  /// The remote's rectangle beside the TV window, on the TV's monitor; null if the TV window isn't found.
  Box? spotBesideTv() {
    final tv = find('Archive TV', 'FLUTTER_RUNNER_WIN32_WINDOW');
    if (tv == 0 || _isVisible(tv) == 0) return null; // not shown yet: its bounds aren't final
    final m = calloc<Int32>(10); // MONITORINFO: cbSize, rcMonitor, rcWork, dwFlags
    try {
      _getWindowRect(tv, m);
      final tvBox = (left: m[0], top: m[1], right: m[2], bottom: m[3]);
      m[0] = 40;
      if (_getMonitorInfo(_monitorFromWindow(tv, 2 /* MONITOR_DEFAULTTONEAREST */), m) == 0) return null;
      final work = (left: m[5], top: m[6], right: m[7], bottom: m[8]);
      final scale = _getDpiForWindow(tv) / 96;
      return placeRemote(tvBox, work, (remoteWidth * scale).round(), (remoteHeight * scale).round());
    } finally {
      calloc.free(m);
    }
  }

  void move(int h, Box b) {
    _showWindow(h, 9); // SW_RESTORE, in case it was minimised
    _setWindowPos(h, 0, b.left, b.top, b.right - b.left, b.bottom - b.top, 0x0004 /* SWP_NOZORDER */);
  }

  Box rect(int h) {
    final r = calloc<Int32>(4);
    try {
      _getWindowRect(h, r);
      return (left: r[0], top: r[1], right: r[2], bottom: r[3]);
    } finally {
      calloc.free(r);
    }
  }

  void front(int h) => _setForeground(h);
}
