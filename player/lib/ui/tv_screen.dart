import 'dart:async';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../engine/tv_engine.dart';
import '../guide/guide_model.dart';
import '../input/actions.dart';
import '../player/player_controller.dart';
import '../settings/settings_store.dart';
import '../settings/window_prefs.dart';
import 'channel_logo.dart';
import 'guide_overlay.dart';
import 'menu_overlay.dart';

enum TvMode { watch, guide, menu }

/// The whole TV: a 4:3 frame holding the video, STAND BY card, info banner and number entry.
class TvScreen extends StatefulWidget {
  final PlayerController controller;
  final Settings settings;
  final SettingsStore store;
  final WindowPrefs windowPrefs;
  const TvScreen({super.key, required this.controller, required this.settings, required this.store, required this.windowPrefs});

  @override
  State<TvScreen> createState() => _TvScreenState();
}

class _TvScreenState extends State<TvScreen> {
  PlayerController get tv => widget.controller;
  final entry = NumberEntry();
  Timer? _entryTimer;
  Timer? _bannerTimer;
  bool _banner = false;
  String? _flashText;
  Timer? _flashTimer;
  Settings get settings => widget.settings;
  TvMode mode = TvMode.watch;
  GuideModel? _guide;
  Timer? _warmTimer;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    tv.addListener(_changed);
  }

  bool _wasStandBy = true;

  void _changed() {
    if (_wasStandBy && !tv.standBy) _showBanner();
    _wasStandBy = tv.standBy;
    if (mounted) setState(() {});
  }

  void _showBanner([Duration d = const Duration(seconds: 5)]) {
    _banner = true;
    _bannerTimer?.cancel();
    _bannerTimer = Timer(d, () {
      if (mounted) setState(() => _banner = false);
    });
  }

  /// Flips to the next/previous tunable channel (wrapping), favorites only when that is on.
  void _flip(int step) {
    final next = flipTarget(tv.engine.tunable, tv.channel?.number, step,
        favorites: settings.favorites, favoritesOnly: settings.favoritesOnly);
    if (next != null) tv.tune(next);
  }

  void _flash(String text) {
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _flashText = null);
    });
    setState(() => _flashText = text);
  }

  /// Saves and applies settings after any change; a failed save is logged, never fatal.
  void _settingsChanged([Settings? _]) {
    tv.setVolume(settings.muted ? 0 : settings.volume);
    try {
      widget.store.save(settings);
    } on Object catch (e) {
      tv.log('settings save failed: $e');
    }
    if (mounted) setState(() {});
  }

  void _toggleFavorite() {
    final c = tv.channel;
    if (c == null) return;
    final added = toggleFavorite(settings, c.number);
    _settingsChanged();
    _flash(added ? 'Added to favorites' : 'Removed from favorites');
  }

  void _openMenu() {
    _entryTimer?.cancel();
    entry.clear();
    setState(() => mode = TvMode.menu);
  }

  void _closeMenu() {
    setState(() => mode = TvMode.watch);
    _focus.requestFocus();
  }

  /// Blocks the airing entry for good and re-tunes, which lands on the next item.
  void _blockCurrent() {
    final c = tv.channel, a = tv.airing;
    _closeMenu();
    if (c == null || a == null) return;
    try {
      tv.engine.blocklist.add(a.slot.entry.id);
    } on Object catch (e) {
      tv.log('blocklist save failed: $e'); // still blocked for this run
    }
    tv.log('${c.name}: blocked ${a.slot.entry.id}');
    _flash('Blocked');
    unawaited(tv.tune(c));
  }

  /// Rebuilds every pool from Archive in the background, one channel at a time.
  void _refresh() {
    _closeMenu();
    _flash('Refreshing channels...');
    unawaited(() async {
      for (final c in tv.engine.channels) {
        await tv.engine.ensurePool(c, maxAge: Duration.zero).catchError((Object e) => tv.log('refresh ${c.number} error: $e'));
      }
      tv.log('refresh done');
    }());
  }

  void _tuneNumber(int n) {
    final c = tv.engine.config.channel(n);
    if (c != null) tv.tune(c);
  }

  void _openGuide() {
    final now = DateTime.now();
    final engine = tv.engine;
    final g = GuideModel(
      channels: engine.channels,
      slotsFor: (c) => engine.guideFor(c, now),
      now: now,
      tunableNumbers: {for (final c in engine.tunable) c.number},
    );
    final i = engine.channels.indexWhere((c) => c.number == tv.channel?.number);
    if (i >= 0) g.selectedRow = i; // open on the channel being watched
    _entryTimer?.cancel();
    entry.clear();
    setState(() {
      _guide = g;
      mode = TvMode.guide;
    });
  }

  void _closeGuide() {
    _warmTimer?.cancel();
    setState(() {
      _guide = null;
      mode = TvMode.watch;
    });
    _focus.requestFocus();
  }

  /// Warms the highlighted channel once the highlight rests for 400 ms.
  void _highlight(Channel c) {
    _warmTimer?.cancel();
    _warmTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(tv.warm(c).catchError((Object e) => tv.log('warm ${c.number} error: $e')));
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final b = keyboardBindings[event.logicalKey];
    if (b == null) return KeyEventResult.ignored;
    // The guide and menu handle their own keys; only favorite, volume, mute and fullscreen reach the TV while open.
    if (mode != TvMode.watch &&
        !const {TvAction.favorite, TvAction.mute, TvAction.volumeUp, TvAction.volumeDown, TvAction.toggleFullscreen}
            .contains(b.action)) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        !const {
          TvAction.channelUp,
          TvAction.channelDown,
          TvAction.volumeUp,
          TvAction.volumeDown,
        }.contains(b.action)) {
      return KeyEventResult.handled;
    }
    switch (b.action) {
      case TvAction.channelUp:
        _flip(1);
      case TvAction.channelDown:
        _flip(-1);
      case TvAction.digit:
        entry.add(b.digit!);
        _entryTimer?.cancel();
        _entryTimer = Timer(const Duration(milliseconds: 1500), _commitEntry);
        setState(() {});
      case TvAction.ok:
        _commitEntry();
      case TvAction.info:
        setState(_showBanner);
      case TvAction.mute:
        settings.muted = !settings.muted;
        _settingsChanged();
      case TvAction.volumeUp:
        settings.volume = (settings.volume + 5).clamp(0, 100).toDouble();
        _settingsChanged();
      case TvAction.volumeDown:
        settings.volume = (settings.volume - 5).clamp(0, 100).toDouble();
        _settingsChanged();
      case TvAction.favorite:
        _toggleFavorite();
      case TvAction.toggleFullscreen:
        widget.windowPrefs.toggleFullScreen();
      case TvAction.back:
        windowManager.isFullScreen().then((f) {
          if (f) widget.windowPrefs.setFullScreen(false);
        });
      case TvAction.guide:
        _openGuide();
      case TvAction.menu:
        _openMenu();
    }
    return KeyEventResult.handled;
  }

  void _commitEntry() {
    _entryTimer?.cancel();
    final n = entry.commit();
    setState(() {});
    if (n != null) _tuneNumber(n);
  }

  @override
  void dispose() {
    tv.removeListener(_changed);
    _entryTimer?.cancel();
    _bannerTimer?.cancel();
    _warmTimer?.cancel();
    _flashTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        onDoubleTap: widget.windowPrefs.toggleFullScreen,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: AspectRatio(
              aspectRatio: 4 / 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Widescreen video is letterboxed inside the 4:3 frame, never stretched or cropped.
                  Video(
                    controller: tv.video,
                    fit: BoxFit.contain,
                    controls: NoVideoControls,
                  ),
                  // Corner bug: the channel's logo, small and faint, while a channel plays.
                  if (settings.cornerBug && !tv.standBy && tv.channel != null)
                    Positioned(
                      top: 16,
                      right: 16,
                      child: Opacity(opacity: 0.5, child: ChannelLogo(channel: tv.channel!, height: 48)),
                    ),
                  if (tv.standBy)
                    StandByCard(channel: tv.channel, message: tv.message),
                  if (_banner && !tv.standBy) InfoBanner(airing: tv.airing),
                  if (entry.text.isNotEmpty)
                    Positioned(top: 24, right: 32, child: _digits(entry.text)),
                  if (_guide != null)
                    GuideOverlay(
                      model: _guide!,
                      onHighlight: _highlight,
                      onClose: _closeGuide,
                      onTune: (c) {
                        _closeGuide();
                        tv.tune(c);
                      },
                    ),
                  if (mode == TvMode.menu)
                    MenuOverlay(
                      settings: settings,
                      current: tv.channel,
                      onChanged: _settingsChanged,
                      onBlockCurrent: _blockCurrent,
                      onRefresh: _refresh,
                      onClose: _closeMenu,
                    ),
                  if (_flashText != null)
                    Positioned(
                      top: 24,
                      left: 32,
                      child: Container(
                        color: const Color(0xE6101A5C),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: Text(
                          _flashText!,
                          style: const TextStyle(color: Color(0xFFFFEB3B), fontSize: 24, fontFamily: 'Consolas'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _digits(String t) => Text(
    t,
    style: const TextStyle(
      color: Colors.greenAccent,
      fontSize: 56,
      fontFamily: 'Consolas',
      fontWeight: FontWeight.bold,
    ),
  );
}

/// Shown instead of the TV when channels.json can't be read.
class ErrorScreen extends StatelessWidget {
  final String message;
  const ErrorScreen({super.key, required this.message});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Center(
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF9EC8FF),
              fontSize: 24,
              fontFamily: 'Consolas',
            ),
          ),
        ),
      ),
    ),
  );
}

class StandByCard extends StatelessWidget {
  final Channel? channel;
  final String? message;
  const StandByCard({super.key, this.channel, this.message});

  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFF0A0A3A),
    alignment: Alignment.center,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (channel != null) ChannelLogo(channel: channel!, height: 140),
        if (channel != null)
          Text(
            '${channel!.number}  ${channel!.name.toUpperCase()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontFamily: 'Consolas',
              fontWeight: FontWeight.bold,
            ),
          ),
        const SizedBox(height: 16),
        Text(
          message ?? 'STAND BY...',
          style: const TextStyle(
            color: Color(0xFF9EC8FF),
            fontSize: 28,
            fontFamily: 'Consolas',
          ),
        ),
      ],
    ),
  );
}

class InfoBanner extends StatelessWidget {
  final Airing? airing;
  const InfoBanner({super.key, this.airing});

  String _left(Duration d) => '${d.inMinutes} min left';

  @override
  Widget build(BuildContext context) {
    final a = airing;
    if (a == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        color: const Color(0xCC0A0A3A),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ChannelLogo(channel: a.channel, height: 64),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${a.channel.number}  ${a.channel.name.toUpperCase()}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontFamily: 'Consolas',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '${cleanTitle(a.slot.entry.title)}  (${_left(a.remaining)})',
                    style: const TextStyle(
                      color: Color(0xFFFFE08A),
                      fontSize: 20,
                      fontFamily: 'Consolas',
                    ),
                  ),
                  if (a.next != null)
                    Text(
                      'Next: ${cleanTitle(a.next!.entry.title)}',
                      style: const TextStyle(
                        color: Color(0xFF9EC8FF),
                        fontSize: 18,
                        fontFamily: 'Consolas',
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
