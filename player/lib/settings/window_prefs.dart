import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
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

/// Aspect of the 4:3 on-screen frame (cards, banner, menus) in a [w] x [h] area: 4:3, but an area within 1.5% of 4:3
/// is filled (no thin black bars from rounding). The video itself is not bound to it.
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
      windowManager.removeListener(this);
      if (_debounce?.isActive ?? false) {
        _debounce!.cancel();
        await _save(); // a move/resize just before closing still counts
      }
      onClose?.call();
    } on Object catch (e) {
      log('on close: $e');
    } finally {
      await windowManager.destroy();
    }
  }

  @override
  void onWindowResized() => _changed();
  @override
  void onWindowMoved() => _changed();
  @override
  void onWindowEnterFullScreen() => _changed();
  @override
  void onWindowLeaveFullScreen() {
    _changed();
  }
}
