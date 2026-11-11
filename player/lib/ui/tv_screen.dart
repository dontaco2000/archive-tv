import 'dart:async';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../engine/tv_engine.dart';
import '../guide/guide_model.dart';
import '../input/actions.dart';
import '../input/gamepad.dart';
import '../player/player_controller.dart';
import '../settings/settings_store.dart';
import '../settings/window_prefs.dart';
import '../weather/weather.dart';
import 'channel_logo.dart';
import 'guide_overlay.dart';
import 'menu_overlay.dart';
import 'arcade_entry.dart';
import 'on_demand_overlay.dart';
import 'weatherstar.dart';

enum TvMode { watch, guide, menu, onDemand, location }

/// The whole TV: a 4:3 frame holding the video, STAND BY card, info banner and number entry.
class TvScreen extends StatefulWidget {
  final PlayerController controller;
  final Settings settings;
  final SettingsStore store;

  /// Null on Android TV / Fire TV, which are always fullscreen.
  final WindowPrefs? windowPrefs;
  const TvScreen({super.key, required this.controller, required this.settings, required this.store, this.windowPrefs});

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
  final _http = http.Client(); // weather data

  bool get _weather => tv.channel?.type == 'weatherstar';

  @override
  void initState() {
    super.initState();
    tv.addListener(_changed);
  }

  bool _wasStandBy = true;
  Channel? _shown;

  void _changed() {
    if (_wasStandBy && !tv.standBy) _showBanner();
    if (_weather && tv.channel != _shown) _showBanner(); // the weather picture is up at once, music or not
    _wasStandBy = tv.standBy;
    _shown = tv.channel;
    if (tv.onDemandEnded && !_endHandled) {
      _endHandled = true;
      _offerNext();
    }
    if (!tv.onDemandEnded) _endHandled = false;
    if (mounted) setState(() {});
  }

  // Play next episode: a 5 s "Next: ..." card after an On Demand title ends.
  bool _endHandled = false;
  Entry? _next;
  int _nextLeft = 0;
  Timer? _nextTimer;

  void _offerNext() {
    final c = tv.channel, e = tv.onDemand;
    if (c == null || e == null) return;
    final n = nextEpisode(tv.engine.poolOf(c), e);
    if (n == null) {
      _flash('End of series: back to live');
      tv.returnToLive();
      return;
    }
    _next = n;
    _nextLeft = 5;
    _nextTimer?.cancel();
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (--_nextLeft <= 0) {
        _playNext();
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  void _cancelNext() {
    _nextTimer?.cancel();
    if (mounted) setState(() => _next = null);
  }

  void _playNext() {
    final c = tv.channel, n = _next;
    _cancelNext();
    if (c != null && n != null) unawaited(tv.playOnDemand(c, n));
  }

  void _openOverlay(TvMode m) {
    _entryTimer?.cancel();
    entry.clear();
    setState(() => mode = m);
  }

  /// Looks up a typed city or ZIP and makes it the weather location.
  Future<void> _setLocation(String text) async {
    _closeMenu();
    if (text.isEmpty) return;
    _flash('Looking up $text...');
    try {
      final p = await geocode(_http, text);
      if (p == null) return _flash('Not found: $text');
      settings
        ..weatherPlace = p.name
        ..weatherLat = p.lat
        ..weatherLon = p.lon;
      _settingsChanged();
      _flash('Weather: ${p.name}');
    } on Object catch (e) {
      tv.log('geocode $text failed: $e');
      _flash('Lookup failed');
    }
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
    final next = flipTarget(
      tv.engine.tunable,
      tv.channel?.number,
      step,
      favorites: settings.favorites,
      favoritesOnly: settings.favoritesOnly,
    );
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

  bool _refreshing = false;

  /// Rebuilds every pool from Archive in the background, one channel at a time (one run at once).
  void _refresh() {
    _closeMenu();
    if (_refreshing) {
      _flash('Refresh already running');
      return;
    }
    _refreshing = true;
    _flash('Refreshing channels...');
    unawaited(() async {
      try {
        for (final c in tv.engine.channels) {
          await tv.engine.ensurePool(c, maxAge: Duration.zero).catchError((Object e) => tv.log('refresh ${c.number} error: $e'));
        }
        tv.log('refresh done');
      } finally {
        _refreshing = false;
      }
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
    // Pad buttons were already re-sent as keyboard keys (input/gamepad.dart); swallow the raw
    // button so Android can't turn an unhandled B into Back.
    if (gamepadKeys.containsKey(event.logicalKey)) return KeyEventResult.handled;
    final b = keyboardBindings[event.logicalKey];
    if (b == null) return KeyEventResult.ignored;
    // The "Next: ..." card takes OK (play now) and Back (cancel, return to live).
    if (_next != null && mode == TvMode.watch && (b.action == TvAction.ok || b.action == TvAction.back)) {
      if (event is KeyRepeatEvent) return KeyEventResult.handled;
      if (b.action == TvAction.ok) {
        _playNext();
      } else {
        _cancelNext();
        tv.returnToLive();
      }
      return KeyEventResult.handled;
    }
    // The guide and menu handle their own keys; only favorite, volume, mute and fullscreen reach the TV while open.
    if (mode != TvMode.watch &&
        !const {TvAction.favorite, TvAction.mute, TvAction.volumeUp, TvAction.volumeDown, TvAction.toggleFullscreen}.contains(b.action)) {
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent &&
        !const {TvAction.channelUp, TvAction.channelDown, TvAction.volumeUp, TvAction.volumeDown}.contains(b.action)) {
      return KeyEventResult.handled;
    }
    // On Demand playback: OK pauses, Left/Right skip 10 s, Back returns to live.
    if (tv.onDemand != null && mode == TvMode.watch) {
      final k = event.logicalKey;
      if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
        tv.seekBy(Duration(seconds: k == LogicalKeyboardKey.arrowLeft ? -10 : 10));
        return KeyEventResult.handled;
      }
      if (b.action == TvAction.ok && entry.text.isEmpty) {
        _flash(tv.player.state.playing ? 'Paused' : 'Play');
        tv.togglePause();
        return KeyEventResult.handled;
      }
      if (b.action == TvAction.back) {
        tv.returnToLive();
        return KeyEventResult.handled;
      }
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
        // The remote's centre button opens the guide unless a channel number is being typed.
        if (event.logicalKey == LogicalKeyboardKey.select && entry.text.isEmpty) {
          _openGuide();
        } else {
          _commitEntry();
        }
      case TvAction.info:
        setState(_showBanner);
      case TvAction.mute:
        settings.muted = !settings.muted;
        _settingsChanged();
      case TvAction.volumeUp:
        settings.volume = (settings.volume + 5).clamp(0, 100).toDouble();
        _settingsChanged();
        _flash('Volume ${settings.volume.round()}');
      case TvAction.volumeDown:
        settings.volume = (settings.volume - 5).clamp(0, 100).toDouble();
        _settingsChanged();
        _flash('Volume ${settings.volume.round()}');
      case TvAction.favorite:
        _toggleFavorite();
      case TvAction.toggleFullscreen:
        widget.windowPrefs?.toggleFullScreen();
      case TvAction.back:
        final w = widget.windowPrefs;
        if (w == null) return KeyEventResult.ignored; // Android's Back key arrives as a route pop: see _systemBack
        windowManager.isFullScreen().then((f) {
          if (f) w.setFullScreen(false);
        });
      case TvAction.guide:
        _openGuide();
      case TvAction.menu:
        _openMenu();
    }
    return KeyEventResult.handled;
  }

  /// The Android remote's Back key (a route pop, never a key event): closes the guide or menu,
  /// otherwise leaves the app.
  void _systemBack() {
    if (mode == TvMode.guide) {
      _closeGuide();
    } else if (mode != TvMode.watch) {
      _closeMenu();
    } else if (_next != null) {
      _cancelNext();
      tv.returnToLive();
    } else if (tv.onDemand != null) {
      tv.returnToLive();
    } else {
      SystemNavigator.pop();
    }
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
    _nextTimer?.cancel();
    _focus.dispose();
    _http.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _systemBack();
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          onDoubleTap: widget.windowPrefs?.toggleFullScreen,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Widescreen video is letterboxed inside the 4:3 frame, never stretched or cropped.
                    Video(controller: tv.video, fit: BoxFit.contain, controls: NoVideoControls),
                    // The weather channel draws its own screens; the player only carries its music.
                    if (_weather)
                      WeatherStarScreen(
                        key: ValueKey(settings.weatherPlace),
                        load: () => fetchWeather(_http, Place(settings.weatherPlace, settings.weatherLat, settings.weatherLon)),
                      ),
                    // Corner bug: the channel's logo, small and faint, while a channel plays.
                    if (settings.cornerBug && !tv.standBy && tv.channel != null && !_weather && tv.onDemand == null)
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Opacity(opacity: 0.5, child: ChannelLogo(channel: tv.channel!, height: 48)),
                      ),
                    if (tv.standBy && !_weather) StandByCard(channel: tv.channel, message: tv.message),
                    if (_banner && _weather) InfoBanner(channel: tv.channel, airing: tv.airing, weatherPlace: settings.weatherPlace),
                    if (_banner && !tv.standBy && !_weather) InfoBanner(channel: tv.channel, airing: tv.airing, onDemand: tv.onDemand),
                    if (entry.text.isNotEmpty) Positioned(top: 24, right: 32, child: _digits(entry.text)),
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
                        onOnDemand: () => _openOverlay(TvMode.onDemand),
                        onWeatherLocation: () => _openOverlay(TvMode.location),
                      ),
                    if (mode == TvMode.onDemand)
                      OnDemandOverlay(
                        channels: [for (final c in tv.engine.tunable) if (c.type == 'archive') c],
                        poolOf: tv.engine.poolOf,
                        onPlay: (c, e) {
                          _closeMenu();
                          unawaited(tv.playOnDemand(c, e));
                        },
                        onClose: _closeMenu,
                      ),
                    if (mode == TvMode.location)
                      ArcadePrompt(
                        title: 'WEATHER LOCATION',
                        hint: 'City or ZIP code. Up/Down: letter, Left/Right: move\nEnter: save, Esc: cancel',
                        onDone: _setLocation,
                        onCancel: _closeMenu,
                      ),
                    if (tv.onDemand != null && !tv.standBy && _next == null)
                      Positioned(
                        top: 16,
                        right: 16,
                        child: Container(
                          color: const Color(0xCCB71C1C),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          child: const Text('ON DEMAND',
                              style: TextStyle(color: Colors.white, fontSize: 18, fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
                        ),
                      ),
                    if (_next != null) NextCard(entry: _next!, secondsLeft: _nextLeft),
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
      ),
    );
  }

  Widget _digits(String t) => Text(
    t,
    style: const TextStyle(color: Colors.greenAccent, fontSize: 56, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
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
            style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 24, fontFamily: 'Consolas'),
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
            style: const TextStyle(color: Colors.white, fontSize: 40, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
          ),
        const SizedBox(height: 16),
        Text(
          message ?? 'STAND BY...',
          style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 28, fontFamily: 'Consolas'),
        ),
      ],
    ),
  );
}

class InfoBanner extends StatelessWidget {
  final Channel? channel;
  final Airing? airing;

  /// Set on the weather channel: the banner names the place, and the music if any.
  final String? weatherPlace;

  /// Set while playing On Demand: the banner shows that title instead of the live slot.
  final Entry? onDemand;
  const InfoBanner({super.key, this.channel, this.airing, this.weatherPlace, this.onDemand});

  String _left(Duration d) => '${d.inMinutes} min left';

  @override
  Widget build(BuildContext context) {
    final a = airing, ch = channel ?? airing?.channel, place = weatherPlace, od = onDemand;
    if (ch == null || (a == null && place == null && od == null)) return const SizedBox.shrink();
    final lines = od != null
        ? ['On Demand: ${cleanTitle(od.title)}', '${(od.durationSeconds / 60).round()} min  (OK pause, Left/Right skip, Back: live)']
        : place != null
        ? ['Local weather for $place', if (a != null) 'Music: ${cleanTitle(a.slot.entry.title)}']
        : ['${cleanTitle(a!.slot.entry.title)}  (${_left(a.remaining)})', if (a.next != null) 'Next: ${cleanTitle(a.next!.entry.title)}'];
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        color: const Color(0xCC0A0A3A),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ChannelLogo(channel: ch, height: 64),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${ch.number}  ${ch.name.toUpperCase()}',
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
                  ),
                  Text(lines[0], style: const TextStyle(color: Color(0xFFFFE08A), fontSize: 20, fontFamily: 'Consolas')),
                  if (lines.length > 1)
                    Text(lines[1], style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 18, fontFamily: 'Consolas')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Next: ..." countdown shown when an On Demand title ends and the series has another episode.
class NextCard extends StatelessWidget {
  final Entry entry;
  final int secondsLeft;
  const NextCard({super.key, required this.entry, required this.secondsLeft});

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          color: const Color(0xEE0A0A3A),
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Next: ${cleanTitle(entry.title)}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 28, fontFamily: 'Consolas', fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Text('Starting in $secondsLeft...   OK: play now   Back: live TV',
                style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 20, fontFamily: 'Consolas')),
          ]),
        ),
      );
}
