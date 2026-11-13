import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'settings_store.dart';

/// [saved] moved (and shrunk, keeping its shape, if it is too big) so it lies fully inside [screen].
Rect clampToScreen(Rect saved, Rect screen) {
  final k = min(1.0, min(screen.width / saved.width, screen.height / saved.height));
  final w = saved.width * k, h = saved.height * k;
  return Rect.fromLTWH(
    saved.left.clamp(screen.left, screen.right - w).toDouble(),
    saved.top.clamp(screen.top, screen.bottom - h).toDouble(),
    w,
    h,
  );
}

/// Outer window size whose client area is exactly 4:3 for the same width: [outer] minus [client]
/// is the title bar and borders, which the 4:3 shape must not include.
Size snap4x3(Size outer, Size client) => Size(outer.width, (client.width * 3 / 4 + outer.height - client.height).roundToDouble());

/// Aspect of the TV frame in a [w] x [h] area: 4:3, but an area within 1.5% of 4:3 is filled
/// (no thin black bars from rounding); fullscreen 16:9 keeps its 4:3 pillarbox.
double frameAspect(double w, double h) {
  if (w <= 0 || h <= 0) return 4 / 3;
  final a = w / h;
  return (a / (4 / 3) - 1).abs() < 0.015 ? a : 4 / 3;
}

/// Remembers window size, position and fullscreen in [Settings] (saved 500 ms after the last change),
/// restores them on launch, and toggles fullscreen on Alt+Enter.
class WindowPrefs with WindowListener {
  final Settings settings;
  final SettingsStore store;
  final void Function(String) log;
  Timer? _debounce;

  WindowPrefs(this.settings, this.store, this.log);

  /// Call before the window is shown: puts it back where it was, clamped onto a connected display.
  static Future<void> restoreBounds(Settings s) async {
    final x = s.windowX, y = s.windowY, w = s.windowW, h = s.windowH;
    if (x == null || y == null || w == null || h == null || w <= 0 || h <= 0) return;
    final saved = Rect.fromLTWH(x, y, w, h);
    final displays = await screenRetriever.getAllDisplays();
    Rect area(Display d) => (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
    final home = displays.map(area).where((r) => r.contains(saved.center)).firstOrNull ??
        area(await screenRetriever.getPrimaryDisplay());
    await windowManager.setBounds(clampToScreen(saved, home));
  }

  /// Runs when the TV window is closed (X, Alt+F4), just before the app goes away.
  void Function()? onClose;

  void attach() {
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true)); // so onWindowClose can run onClose first
    HardwareKeyboard.instance.addHandler(_altEnter);
  }

  bool _altEnter(KeyEvent e) {
    if (e is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) return false;
    if (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.numpadEnter) return false;
    toggleFullScreen();
    return true;
  }

  /// All fullscreen changes go through here: window_manager on Windows only reports
  /// entering fullscreen for maximized windows, so the listener alone would miss most.
  Future<void> setFullScreen(bool on) async {
    await windowManager.setFullScreen(on);
    _changed();
  }

  Future<void> toggleFullScreen() async => setFullScreen(!await windowManager.isFullScreen());

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => unawaited(_save()));
  }

  Future<void> _save() async {
    try {
      settings.fullscreen = await windowManager.isFullScreen();
      // Only a normal window's bounds are worth restoring; fullscreen/maximized keep the last normal ones.
      if (!settings.fullscreen && !await windowManager.isMaximized() && !await windowManager.isMinimized()) {
        final b = await windowManager.getBounds();
        settings
          ..windowX = b.left
          ..windowY = b.top
          ..windowW = b.width
          ..windowH = b.height;
      }
      store.save(settings);
    } on Object catch (e) {
      log('window prefs save failed: $e');
    }
  }

  @override
  Future<void> onWindowClose() async {
    try {
      onClose?.call();
    } on Object catch (e) {
      log('on close: $e');
    } finally {
      await windowManager.destroy();
    }
  }

  /// Windowed: sets the height so the client area (not the whole window) is 4:3, and lets the live
  /// drag keep that shape. Runs after a drag ends ('resized'), on launch, never while maximized/fullscreen.
  Future<void> snapToFourThree() async {
    try {
      if (await windowManager.isFullScreen() || await windowManager.isMaximized()) return;
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final client = view.physicalSize / view.devicePixelRatio;
      if (client.isEmpty) return;
      final b = await windowManager.getBounds();
      final t = snap4x3(b.size, client);
      if ((t.height - b.height).abs() > 1) await windowManager.setSize(t);
    } on Object catch (e) {
      log('4:3 snap failed: $e');
    }
  }

  Timer? _snapTimer;

  /// Snaps shortly AFTER the resize settles (a live drag or the exit from fullscreen sends a burst of events).
  void _snapSoon() {
    _snapTimer?.cancel();
    _snapTimer = Timer(const Duration(milliseconds: 700), () => unawaited(snapToFourThree().then((_) => _changed())));
  }

  @override
  void onWindowResized() => _snapSoon();
  @override
  void onWindowMoved() => _changed();
  @override
  void onWindowEnterFullScreen() => _changed();
  @override
  void onWindowLeaveFullScreen() {
    _changed();
    _snapSoon();
  }
}
