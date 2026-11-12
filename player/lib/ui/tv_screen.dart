import 'dart:async';
import 'dart:io';
import 'dart:math';

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
import '../parental/parental_flow.dart';
import '../parental/parental_ui.dart';
import '../player/captions.dart';
import '../player/picture.dart';
import '../player/player_controller.dart';
import '../remote/remote_server.dart';
import '../settings/crash_log.dart';
import '../settings/settings_file.dart';
import '../settings/settings_store.dart';
import '../settings/window_prefs.dart';
import '../weather/weather.dart';
import 'about_overlay.dart';
import 'channel_logo.dart';
import 'credits_overlay.dart';
import 'guide_overlay.dart';
import 'menu_overlay.dart';
import 'arcade_entry.dart';
import 'on_demand_overlay.dart';
import 'weather_web.dart';

enum TvMode { watch, guide, menu, onDemand, location, about, credits, parental }

/// The whole TV: a 4:3 frame holding the video, STAND BY card, info banner and number entry.
class TvScreen extends StatefulWidget {
  final PlayerController controller;
  final Settings settings;
  final SettingsStore store;

  /// Null on Android TV / Fire TV, which are always fullscreen.
  final WindowPrefs? windowPrefs;

  /// The remote-control server (Windows only); null hides the remote menu items and R key.
  final RemoteServer? remote;

  /// The crash log (last error, log folder); null in tests.
  final CrashLog? crash;
  const TvScreen({super.key, required this.controller, required this.settings, required this.store, this.windowPrefs, this.remote, this.crash});

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

  // WeatherStar 4000+ page state for the current tune; the native screens cover it until it loads
  // and replace it if it fails.
  bool _webFailed = false, _webLoaded = false;
  int _webTune = 0;
  bool get _webWeather => useWebWeather(settings.weatherMode, webAvailable: webViewAvailable, pageFailed: _webFailed);

  @override
  void initState() {
    super.initState();
    // The startup tune can happen before this screen listens; without this the first later notify
    // (e.g. the music's first frame) looks like a channel change and drops the loaded WeatherStar page.
    _shown = tv.channel;
    tv.addListener(_changed);
    tv.onLocked = _askUnlock;
    tv.engine.poolsChanged.addListener(_poolsChanged);
    if (!settings.noticeAccepted) mode = TvMode.about; // one-time content notice
    widget.remote
      ?..state = _remoteState
      ..volume = _setVolume
      ..channel = _remoteTune
      ..setting = _remoteSetting
      ..parentalPin = ((pin) => _pin?.onPin(pin))
      ..logo = _logoBytes;
    final r = widget.remote;
    if (r != null) {
      _remoteWatch = Timer.periodic(const Duration(seconds: 1), (_) {
        final open = r.isWindowOpen();
        if (open != _remoteOpen && mounted) setState(() => _remoteOpen = open);
      });
    }
  }

  // ---- Remote control (remote/remote_server.dart). Its buttons arrive as key presses; these cover the rest.

  Map<String, Object?> _remoteState() {
    final c = tv.channel, a = tv.airing, od = tv.onDemand;
    return {
      'channel': c == null ? null : {'number': c.number, 'name': c.name},
      'title': od != null ? cleanTitle(od.title) : (a == null ? null : cleanTitle(a.slot.entry.title)),
      'minutesLeft': od == null && a != null ? a.remaining.inMinutes : null,
      'onDemand': od != null,
      'standBy': tv.standBy,
      'message': tv.message,
      'building': tv.message == buildingMessage,
      'volume': settings.volume.round(),
      'muted': settings.muted,
      'mode': mode.name.toLowerCase(),
      'favorite': c != null && settings.favorites.contains(c.number),
      'entry': entry.text,
      'captionsOn': settings.captionsOn,
      'captionSize': settings.captionSize,
      'captions': tv.captionState,
      'leveling': settings.volumeLeveling,
      'levelingAvailable': tv.levelingAvailable,
      'weatherMode': settings.weatherMode,
      'picture': settings.picture,
      'audioDelay': tv.itemId == null ? 0 : settings.audioDelays[tv.itemId] ?? 0,
      'remoteLan': settings.remoteLan,
      'sleep': sleepMinutesLeft(_sleepAt, DateTime.now()),
      'pinPrompt': _pin == null ? null : {'id': _pin!.id, 'title': _pin!.title, 'hint': _pin!.hint},
    };
  }

  // ---- Parental controls (parental/): the PIN prompt goes over everything; the remote page answers it too.
  PinRequest? _pin;
  late final ParentalFlow _parental = ParentalFlow(settings.parental, save: _settingsChanged, flash: _flash, ask: _ask, log: tv.log)
    ..afterLockOn = _leaveLocked;

  void _ask(PinRequest? r) {
    if (!mounted) return;
    setState(() => _pin = r);
    if (r == null && mode == TvMode.watch) _focus.requestFocus();
  }

  /// Tuning a locked channel (PlayerController.onLocked): the PIN turns the lock OFF, then it tunes.
  void _askUnlock(Channel c) => _parental.unlockFor('${c.number} ${c.name.toUpperCase()}', () => unawaited(tv.tune(c)));

  /// The lock just went ON: leave the channel on screen if it is a locked one (for the next open channel up).
  void _leaveLocked() {
    final c = tv.channel;
    if (c == null || !tv.isLocked(c)) return;
    final open = settings.parental.openChannels(tv.engine.tunable);
    final next = open.where((o) => o.number > c.number).firstOrNull ?? open.firstOrNull;
    if (next != null) unawaited(tv.tune(next));
  }

  void _setVolume(int level) {
    settings
      ..volume = level.toDouble()
      ..muted = false;
    _settingsChanged();
    _flash('Volume $level');
  }

  /// POST /api/setting from the remote's settings panel (values already checked by the server).
  void _remoteSetting(String name, Object value) {
    switch (name) {
      case 'captionsOn':
        settings.captionsOn = value as bool;
        _flash('Captions: ${settings.captionsOn ? 'ON' : 'OFF'}');
      case 'captionSize':
        settings.captionSize = value as int;
        _flash('Caption size ${settings.captionSize}');
      case 'leveling':
        settings.volumeLeveling = value as String;
      case 'weatherMode':
        settings.weatherMode = value as String;
      case 'picture':
        settings.picture = value as String;
        _flash('Picture: ${settings.picture.toUpperCase()}');
    }
    _settingsChanged();
  }

  void _remoteTune(int n) {
    if (mode == TvMode.guide) {
      _closeGuide();
    } else if (mode != TvMode.watch) {
      _closeMenu();
    }
    _tuneNumber(n);
  }

  Future<List<int>?> _logoBytes(int n) async {
    final c = tv.engine.config.channel(n);
    if (c == null) return null;
    try {
      return (await rootBundle.load(logoAsset(c.name))).buffer.asUint8List();
    } on Object {
      return null;
    }
  }

  /// R key, menu item and the REMOTE corner button: open the remote window if closed, else close it.
  Future<void> _toggleRemote() async {
    final r = widget.remote;
    if (r == null) return;
    if (!_remoteOpen) _flash('Opening remote...');
    final open = await r.toggleWindow();
    if (!mounted) return;
    setState(() => _remoteOpen = open);
    if (!open) _flash('Remote closed');
  }

  // Remote window state, re-read each second so closing it with its X turns the button back to OFF.
  bool _remoteOpen = false;
  Timer? _remoteWatch;

  // The REMOTE corner button shows while the mouse moves over the window, and fades 3 s after it stops.
  bool _mouseActive = false;
  Timer? _mouseTimer;

  void _mouseMoved() {
    _mouseTimer?.cancel();
    _mouseTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _mouseActive = false);
    });
    if (!_mouseActive) setState(() => _mouseActive = true);
  }

  bool _wasStandBy = true;
  Channel? _shown;
  Channel? _previous; // the channel before this one (this run only; startup resumes settings.lastChannel)

  /// L key / remote LAST: back to the previous channel, so two presses flip between two channels.
  void _lastChannel() {
    final p = _previous;
    if (p == null) return _flash('No last channel');
    unawaited(tv.tune(p));
  }

  /// X key / menu: the program on screen doesn't belong on this channel. Logged for audits
  /// (wrong_channel.jsonl), its item kept off this channel for good, and on to what airs next.
  void _wrongChannel() {
    if (mode != TvMode.watch) _closeMenu();
    final c = tv.channel, e = tv.onDemand ?? tv.airing?.slot.entry;
    if (c == null || e == null || _weather) return _flash('Nothing to remove');
    tv.engine.markWrongChannel(c, e);
    _flash('REMOVED FROM THIS CHANNEL');
    if (tv.onDemand != null) {
      _cancelNext();
      tv.returnToLive();
    } else {
      unawaited(tv.tune(c));
    }
  }

  // ---- Sleep timer: T, the menu item and the remote's SLEEP step Off/15/30/60/90/120 min. When it runs out a
  // 20 s "Going to sleep" card comes up (any key stays), the sound fades over its last 10 s, then the app turns off.
  int _sleepStep = 0;
  DateTime? _sleepAt;
  int? _sleepCard; // seconds left on the card; null while it isn't up
  Timer? _sleepTimer;

  void _cycleSleep() {
    _sleepTimer?.cancel();
    _sleepStep = nextSleepStep(_sleepStep);
    _sleepAt = _sleepStep == 0 ? null : DateTime.now().add(Duration(minutes: _sleepStep));
    if (_sleepAt != null) _sleepTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sleepTick());
    _flash(_sleepStep == 0 ? 'SLEEP OFF' : 'SLEEP $_sleepStep MIN');
  }

  void _sleepTick() {
    final at = _sleepAt;
    if (at == null || !mounted) return;
    if (_sleepCard == null) {
      if (DateTime.now().isBefore(at)) {
        if (mode == TvMode.menu || _banner) setState(() {}); // minutes left in the menu item / SLEEP marker
        return;
      }
      if (_guide != null) {
        _closeGuide();
      } else if (mode != TvMode.watch) {
        _closeMenu();
      }
      _sleepCard = 20;
    } else {
      _sleepCard = _sleepCard! - 1;
    }
    final left = _sleepCard!;
    if (left <= 10 && !settings.muted) tv.setVolume(settings.volume * left / 10);
    if (left <= 0) {
      _sleepTimer?.cancel();
      unawaited(_goToSleep());
    }
    setState(() {});
  }

  /// Any key on the "Going to sleep" card: the timer is off and the sound comes back.
  void _stayAwake() {
    _sleepTimer?.cancel();
    _sleepStep = 0;
    _sleepAt = _sleepCard = null;
    tv.setVolume(settings.muted ? 0 : settings.volume);
    _flash('SLEEP OFF');
  }

  /// Windows: the same clean shutdown as the window's X and the remote's POWER. Android: stop and go to the
  /// home screen so the stick can sleep.
  Future<void> _goToSleep() async {
    tv.log('sleep timer: turning off');
    if (!Platform.isAndroid) return windowManager.close();
    await tv.player.stop();
    _sleepStep = 0;
    _sleepAt = _sleepCard = null;
    tv.setVolume(settings.muted ? 0 : settings.volume); // a later resume of this run plays at the usual level
    await SystemNavigator.pop();
  }

  void _changed() {
    if (_wasStandBy && !tv.standBy) _showBanner();
    if (tv.channel != _shown) {
      if (_shown != null && tv.channel != null) _previous = _shown; // L / LAST flips back to it
      if (_weather) _showBanner(); // the weather picture is up at once, music or not
      _webFailed = _webLoaded = false; // every tune tries the WeatherStar page again...
      _webTune++; // ...in a fresh WebView, so "loaded" always belongs to the page on screen
    }
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
      settings.parental.openChannels(tv.engine.tunable), // locked channels are skipped
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
    unawaited(tv.setLeveling(settings.volumeLeveling));
    unawaited(tv.setCaptions(settings.captionsOn));
    unawaited(tv.setPicture(settings.picture));
    final r = widget.remote;
    if (r != null) {
      r.ensurePin(); // first LAN enable makes the PIN; saved below
      unawaited(
        r.start().then((_) {
          if (mounted) setState(() {}); // the menu shows the LAN address once it is known
        }),
      );
    }
    _webFailed = false; // e.g. switched back to the WeatherStar view: try the page again
    try {
      widget.store.save(settings);
    } on Object catch (e) {
      tv.log('settings save failed: $e');
    }
    if (mounted) setState(() {});
  }

  /// [ / ] / \ keys: shift (or reset, [step] 0) the audio of the item on screen; saved for that item.
  void _nudgeAudio(int step) {
    final id = tv.itemId;
    if (id == null || tv.standBy) return _flash('A/V sync: nothing playing');
    final ms = nudgeAudioDelay(settings, id, step);
    unawaited(tv.setAudioDelay(ms));
    _settingsChanged();
    _flash(ms == 0 ? 'A/V sync: reset' : 'A/V sync: audio ${ms > 0 ? '+' : ''}$ms ms');
  }

  void _copyLastError() {
    final e = widget.crash?.lastError;
    if (e == null) return _flash('No errors recorded');
    unawaited(Clipboard.setData(ClipboardData(text: e)));
    _flash('Last error copied');
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

  /// Closing About (or the first-run notice) counts as having seen the content notice.
  void _closeAbout() {
    if (!settings.noticeAccepted) {
      settings.noticeAccepted = true;
      _settingsChanged();
    }
    _closeMenu();
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
    // The guide reaches to the end of the last saved day snapshot (today plus six more). Rows start
    // at midnight so blocks that began earlier (marathons, 2-hour blocks) keep their real length.
    final hours = DateTime(now.year, now.month, now.day + 7).difference(now).inHours;
    final midnight = DateTime(now.year, now.month, now.day);
    final g = GuideModel(
      channels: engine.channels,
      slotsFor: (c) => engine.guideFor(c, midnight, hours: 24 * 7),
      now: now,
      tunableNumbers: {for (final c in engine.tunable) c.number},
      buildingNumbers: {for (final c in engine.channels) if (engine.statusOf(c) == PoolStatus.building) c.number},
      lockedNumbers: {for (final c in engine.channels) if (tv.isLocked(c)) c.number},
      horizon: now.add(Duration(hours: hours)),
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

  /// A pool finished loading/building: an open guide picks up channels that went on (or off) air.
  void _poolsChanged() {
    final g = _guide, engine = tv.engine;
    if (g == null || !mounted) return;
    setState(() {
      g.tunableNumbers
        ..clear()
        ..addAll([for (final c in engine.tunable) c.number]);
      g.buildingNumbers
        ..clear()
        ..addAll([for (final c in engine.channels) if (engine.statusOf(c) == PoolStatus.building) c.number]);
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
    if (_sleepCard != null) {
      if (event is! KeyRepeatEvent) _stayAwake(); // any key keeps the TV on
      return KeyEventResult.handled;
    }
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
      case TvAction.onDemand:
        _openOverlay(TvMode.onDemand);
      case TvAction.picture:
        settings.picture = cyclePicture(settings.picture, 1);
        _settingsChanged();
        _flash('Picture: ${settings.picture.toUpperCase()}');
      case TvAction.remote:
        if (widget.remote == null) return KeyEventResult.ignored;
        unawaited(_toggleRemote());
      case TvAction.audioEarlier:
        _nudgeAudio(-audioDelayStepMs);
      case TvAction.audioLater:
        _nudgeAudio(audioDelayStepMs);
      case TvAction.audioReset:
        _nudgeAudio(0);
      case TvAction.sleep:
        _cycleSleep();
      case TvAction.lastChannel:
        _lastChannel();
      case TvAction.wrongChannel:
        _wrongChannel();
    }
    return KeyEventResult.handled;
  }

  /// The Android remote's Back key (a route pop, never a key event): closes the guide or menu,
  /// otherwise leaves the app.
  void _systemBack() {
    if (_pin != null) {
      _ask(null);
    } else if (_sleepCard != null) {
      _stayAwake();
    } else if (mode == TvMode.guide) {
      _closeGuide();
    } else if (mode == TvMode.about) {
      _closeAbout();
    } else if (mode == TvMode.credits) {
      _closeMenu();
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
    tv.engine.poolsChanged.removeListener(_poolsChanged);
    _entryTimer?.cancel();
    _bannerTimer?.cancel();
    _warmTimer?.cancel();
    _flashTimer?.cancel();
    _nextTimer?.cancel();
    _remoteWatch?.cancel();
    _mouseTimer?.cancel();
    _sleepTimer?.cancel();
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
        child: MouseRegion(
          onHover: widget.remote == null ? null : (_) => _mouseMoved(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onDoubleTap: widget.windowPrefs?.toggleFullScreen,
                child: Scaffold(
                  backgroundColor: Colors.black,
                  body: LayoutBuilder(
                    builder: (context, box) => Center(
                      child: AspectRatio(
                        aspectRatio: frameAspect(box.maxWidth, box.maxHeight),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // Widescreen video is letterboxed inside the 4:3 frame, never stretched; Picture FILL
                            // covers the frame instead (overflow cropped), and baked-in borders are cut (tv.crop).
                            // Captions sit at the bottom of the 4:3 frame, sized from its height (captions.dart).
                            _video(captionStyle(
                              min(box.maxHeight, box.maxWidth / frameAspect(box.maxWidth, box.maxHeight)),
                              settings.captionSize,
                              visible: tv.captionState == 'on' || tv.captionState == 'forced',
                            )),
                            // The weather channel shows the WeatherStar 4000+ page (spec 5.8); the player only carries its music.
                            if (_weather)
                              WeatherLayers(
                                key: ValueKey(_webTune),
                                place: settings.weatherPlace,
                                web: _webWeather,
                                webLoaded: _webLoaded,
                                url: weatherStarUrl(
                                  place: settings.weatherPlace,
                                  lat: settings.weatherLat,
                                  lon: settings.weatherLon,
                                  light: weatherStarLight,
                                ),
                                load: () => fetchWeather(_http, Place(settings.weatherPlace, settings.weatherLat, settings.weatherLon)),
                                onLoaded: () {
                                  tv.log('weatherstar page loaded');
                                  if (mounted) setState(() => _webLoaded = true);
                                },
                                onFailed: (why) {
                                  tv.log('weatherstar page failed ($why): native weather screens instead');
                                  if (mounted) setState(() => _webFailed = true);
                                },
                              ),
                            // Corner bug: the channel's logo, small and faint, while a channel plays.
                            if (settings.cornerBug && !tv.standBy && tv.channel != null && !_weather && tv.onDemand == null)
                              Positioned(
                                top: 16,
                                right: 16,
                                child: Opacity(opacity: 0.5, child: ChannelLogo(channel: tv.channel!, height: 48)),
                              ),
                            if (tv.standBy && !_weather) StandByCard(channel: tv.channel, message: tv.message),
                            if (_banner && _weather)
                              InfoBanner(channel: tv.channel, airing: tv.airing, weatherPlace: settings.weatherPlace),
                            if (_banner && !tv.standBy && !_weather)
                              InfoBanner(
                                channel: tv.channel,
                                airing: tv.airing,
                                onDemand: tv.onDemand,
                                sleepMinutes: sleepMinutesLeft(_sleepAt, DateTime.now()),
                              ),
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
                                onAbout: () => _openOverlay(TvMode.about),
                                onCredits: () => _openOverlay(TvMode.credits),
                                lastError: widget.crash?.lastError,
                                onCopyLastError: _copyLastError,
                                onOpenLogFolder: widget.crash == null || !Platform.isWindows
                                    ? null
                                    : () {
                                        _closeMenu();
                                        unawaited(openExternal(widget.crash!.dir.path, tv.log));
                                      },
                                levelingAvailable: tv.levelingAvailable,
                                onOpenRemote: widget.remote == null
                                    ? null
                                    : () {
                                        _closeMenu();
                                        unawaited(_toggleRemote());
                                      },
                                remoteOpen: _remoteOpen,
                                onWrongChannel: _wrongChannel,
                                onSleep: _cycleSleep,
                                sleepStep: _sleepStep,
                                sleepLeft: sleepMinutesLeft(_sleepAt, DateTime.now()),
                                onParental: () => _openOverlay(TvMode.parental),
                                onOpenSettingsFile: !Platform.isWindows || widget.store.textFile == null
                                    ? null
                                    : () {
                                        _closeMenu();
                                        unawaited(openSettingsFile(widget.store.textFile!, settings, tv.log));
                                      },
                                remoteLanInfo: widget.remote == null || !settings.remoteLan
                                    ? null
                                    : 'Phone: ${widget.remote!.lanUrl ?? 'finding address...'}  PIN ${settings.remotePin ?? '-'}',
                              ),
                            if (mode == TvMode.onDemand)
                              OnDemandOverlay(
                                channels: [
                                  for (final c in settings.parental.openChannels(tv.engine.tunable)) // locked channels' items hidden
                                    if (c.type == 'archive') c,
                                ],
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
                            if (mode == TvMode.about)
                              AboutOverlay(
                                firstRun: !settings.noticeAccepted,
                                onClose: _closeAbout,
                                onCredits: () => _openOverlay(TvMode.credits),
                              ),
                            if (mode == TvMode.credits) CreditsOverlay(onClose: _closeMenu, log: tv.log),
                            if (mode == TvMode.parental)
                              ParentalOverlay(
                                parental: settings.parental,
                                channels: tv.engine.channels,
                                flow: _parental,
                                active: _pin == null,
                                onChanged: _settingsChanged,
                                onClose: _closeMenu,
                              ),
                            if (tv.onDemand != null && !tv.standBy && _next == null)
                              Positioned(
                                top: 16,
                                right: 16,
                                child: Container(
                                  color: const Color(0xCCB71C1C),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  child: const Text(
                                    'ON DEMAND',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontFamily: 'Consolas',
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            if (_next != null) NextCard(entry: _next!, secondsLeft: _nextLeft),
                            if (_sleepCard != null) SleepCard(secondsLeft: _sleepCard!),
                            if (_pin != null) PinPrompt(key: ValueKey(_pin!.id), request: _pin!, onCancel: () => _ask(null)),
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
              if (widget.remote != null)
                Positioned(
                  top: 10,
                  right: 10,
                  child: IgnorePointer(
                    ignoring: !_mouseActive,
                    child: AnimatedOpacity(
                      opacity: _mouseActive ? 1 : 0,
                      duration: const Duration(milliseconds: 400),
                      child: RemoteCornerButton(on: _remoteOpen, onTap: () => unawaited(_toggleRemote())),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The video, cut to [PlayerController.crop] when the file has baked-in borders. Captions then go on top
  /// of the frame instead of inside the cropped video, where they would be cut or scaled with it.
  Widget _video(SubtitleViewConfiguration captions) {
    final fit = settings.picture == 'fill' ? BoxFit.cover : BoxFit.contain;
    final c = tv.crop, p = tv.player.state.videoParams;
    final dw = (p.dw ?? 0).toDouble(), dh = (p.dh ?? 0).toDouble();
    if (c == null || dw <= 0 || dh <= 0) {
      return Video(controller: tv.video, fit: fit, controls: NoVideoControls, subtitleViewConfiguration: captions);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: FittedBox(
            fit: fit,
            child: SizedBox(
              width: dw * c.w,
              height: dh * c.h,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: -dw * c.x,
                      top: -dh * c.y,
                      width: dw,
                      height: dh,
                      child: Video(
                        controller: tv.video,
                        fit: BoxFit.fill,
                        controls: NoVideoControls,
                        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (captions.visible) SubtitleView(controller: tv.video, configuration: captions),
      ],
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

/// "STAND BY" with dots cycling . .. ... (padded, so the text never shifts); a [message] (NO SIGNAL, OFF AIR,
/// the build-mode notice) shows as is.
String standByText(String? message, int tick) => message ?? 'STAND BY${'.' * (tick % 3 + 1)}'.padRight(11);

class StandByCard extends StatefulWidget {
  final Channel? channel;
  final String? message;
  const StandByCard({super.key, this.channel, this.message});

  @override
  State<StandByCard> createState() => _StandByCardState();
}

class _StandByCardState extends State<StandByCard> {
  int _tick = 0;
  late final Timer _dots;

  @override
  void initState() {
    super.initState();
    _dots = Timer.periodic(const Duration(milliseconds: 450), (_) => setState(() => _tick++));
  }

  @override
  void dispose() {
    _dots.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = widget.channel;
    return Container(
      color: const Color(0xFF0A0A3A),
      alignment: Alignment.center,
      // scaleDown: a small window shrinks the card instead of overflowing it.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (channel != null) ChannelLogo(channel: channel, height: 280),
          if (channel != null)
            Text(
              '${channel.number}  ${channel.name.toUpperCase()}',
              style: const TextStyle(color: Colors.white, fontSize: 40, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
            ),
          const SizedBox(height: 16),
          Text(
            standByText(widget.message, _tick),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 28, fontFamily: 'Consolas'),
          ),
        ],
      ),
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  final Channel? channel;
  final Airing? airing;

  /// Set on the weather channel: the banner names the place, and the music if any.
  final String? weatherPlace;

  /// Set while playing On Demand: the banner shows that title instead of the live slot.
  final Entry? onDemand;

  /// Minutes left on the sleep timer (null: off): a SLEEP marker at the right.
  final int? sleepMinutes;
  const InfoBanner({super.key, this.channel, this.airing, this.weatherPlace, this.onDemand, this.sleepMinutes});

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
                    '${ch.number}  ${ch.name.toUpperCase()}${switch (a == null || od != null ? null : themeLabelOf(ch, a.slot)) {
                      final t? => '  ·  $t',
                      _ => '',
                    }}',
                    style: const TextStyle(color: Colors.white, fontSize: 26, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
                  ),
                  Text(
                    lines[0],
                    style: const TextStyle(color: Color(0xFFFFE08A), fontSize: 20, fontFamily: 'Consolas'),
                  ),
                  if (lines.length > 1)
                    Text(
                      lines[1],
                      style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 18, fontFamily: 'Consolas'),
                    ),
                ],
              ),
            ),
            if (sleepMinutes != null)
              Text(
                'SLEEP $sleepMinutes',
                style: const TextStyle(color: Color(0xFFFFEB3B), fontSize: 20, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
              ),
          ],
        ),
      ),
    );
  }
}

/// The sleep timer ran out: shown for 20 s before the TV turns off; any key keeps it on.
class SleepCard extends StatelessWidget {
  final int secondsLeft;
  const SleepCard({super.key, required this.secondsLeft});

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      color: const Color(0xEE0A0A3A),
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Going to sleep...',
            style: TextStyle(color: Colors.white, fontSize: 32, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            'Press any key to stay   ($secondsLeft)',
            style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 22, fontFamily: 'Consolas'),
          ),
        ],
      ),
    ),
  );
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Next: ${cleanTitle(entry.title)}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 28, fontFamily: 'Consolas', fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Text(
            'Starting in $secondsLeft...   OK: play now   Back: live TV',
            style: const TextStyle(color: Color(0xFF9EC8FF), fontSize: 20, fontFamily: 'Consolas'),
          ),
        ],
      ),
    ),
  );
}

/// The REMOTE ON/OFF button in the window's top-right corner (Windows). Not focusable: a click
/// never takes the keyboard away from the TV.
class RemoteCornerButton extends StatelessWidget {
  final bool on;
  final VoidCallback onTap;
  const RemoteCornerButton({super.key, required this.on, required this.onTap});

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xF0101A5C),
          border: Border.all(color: const Color(0xFFFFEB3B), width: 2),
        ),
        child: Text(
          'REMOTE: ${on ? 'ON' : 'OFF'}',
          style: TextStyle(
            color: on ? const Color(0xFFFFEB3B) : Colors.white,
            fontSize: 20,
            fontFamily: 'Consolas',
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}
