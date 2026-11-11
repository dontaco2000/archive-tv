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

  void attach() {
    windowManager.addListener(this);
    HardwareKeyboard.instance.addHandler(_altEnter);
  }

  bool _altEnter(KeyEvent e) {
    if (e is! KeyDownEvent || !HardwareKeyboard.instance.isAltPressed) return false;
    if (e.logicalKey != LogicalKeyboardKey.enter && e.logicalKey != LogicalKeyboardKey.numpadEnter) return false;
    windowManager.isFullScreen().then((f) => windowManager.setFullScreen(!f));
    return true;
  }

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
  void onWindowResized() => _changed();
  @override
  void onWindowMoved() => _changed();
  @override
  void onWindowEnterFullScreen() => _changed();
  @override
  void onWindowLeaveFullScreen() => _changed();
}
