import 'dart:async';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../engine/tv_engine.dart';
import '../settings/settings_store.dart';
import 'captions.dart';
import 'stall_watch.dart';

/// Owns the single libmpv player. `tune` shows STAND BY, opens the airing file
/// at its offset, and clears STAND BY on the first frame.
class PlayerController extends ChangeNotifier {
  final TvEngine engine;
  final Player player = Player(configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024));
  late final VideoController video = VideoController(player);
  final void Function(String) log;

  /// mpv commands for captions; replaceable in tests (no libmpv there).
  MpvCommand mpv = (_) async {};

  /// The viewer's CC switch (English programmes); foreign ones always get English subtitles.
  bool captionsOn = false;

  /// Captions for the file on screen (see [CaptionState]).
  CaptionState captionState = 'off';
  Entry? _captioned; // the file [captionState] belongs to
  bool _forceForeign = false;

  Channel? channel;
  Airing? airing;
  bool standBy = true;
  String? message;

  /// Milliseconds from tune() to first frame, most recent first (for the latency test).
  final List<int> tuneTimes = [];

  int _generation = 0; // bumped on every tune so a stale open can't clear a newer STAND BY
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<PlayerLog>? _logSub;
  Timer? _slotTimer; // re-tunes when the airing slot ends
  Timer? _retryTimer; // re-tunes a NO SIGNAL channel after a while
  Timer? _stallTimer; // watches for playback that stops moving after the first frame

  PlayerController(this.engine, {void Function(String)? log}) : log = log ?? ((_) {}) {
    final native = player.platform;
    if (native is NativePlayer) {
      mpv = (args) => native.command(args);
      // Fast start: small probe, hardware decoding, modest read-ahead.
      native.setProperty('hwdec', 'auto');
      native.setProperty('demuxer-readahead-secs', '6');
      native.setProperty('cache-secs', '10');
      native.setProperty('demuxer-lavf-probesize', '262144');
      native.setProperty('demuxer-lavf-analyzeduration', '0.5');
      native.setProperty('video-aspect-override', 'no');
      // No usable sound device must not freeze audio-only files (weather music): play on silently.
      native.setProperty('audio-fallback-to-null', 'yes');
    }
    // Sound problems are otherwise invisible: log mpv's audio-output errors and warnings.
    _logSub = player.stream.log.listen((l) {
      // Also audio filter (volume leveling) failures: mpv then drops the filter and plays unfiltered.
      if (const {'ao', 'audio', 'af', 'lavfi', 'user_filter_wrapper'}.contains(l.prefix) ||
          l.text.toLowerCase().contains('audio device') ||
          l.text.contains('Disabling filter')) {
        this.log('mpv ${l.level} ${l.prefix}: ${l.text.trim()}');
      }
      // The filter chain is only built when audio starts: a libmpv without these lavfi filters fails here.
      if (levelingAvailable && (l.prefix == 'lavfi' || (l.prefix == 'user_filter_wrapper' && l.text.contains('failed')))) {
        unawaited(_levelingUnavailable(reopen: true));
      }
    });
    _completedSub = player.stream.completed.listen((done) {
      if (done && onDemand != null && !standBy && !onDemandEnded) {
        onDemandEnded = true; // the screen offers the next episode or returns to live
        notifyListeners();
        return;
      }
      // Only a file that ended with its slot moves on; one that ends early waits for the slot timer.
      final a = airing;
      if (done && channel != null && a != null && !DateTime.now().isBefore(a.slot.end.subtract(const Duration(milliseconds: 500)))) {
        _safeTune(channel!);
      }
    });
  }

  void _safeTune(Channel c, {int attempt = 0}) =>
      unawaited(tune(c, attempt: attempt).catchError((Object e) => log('tune ${c.number} error: $e')));

  /// After the first frame: if the position stops moving for 8 s while playing, [onStall] runs once.
  void _watchStall(int gen, VoidCallback onStall) {
    _stallTimer?.cancel();
    final w = StallWatch(now: DateTime.now());
    _stallTimer = Timer.periodic(const Duration(seconds: 2), (t) {
      if (gen != _generation) return t.cancel();
      final s = player.state;
      if (w.check(s.position, DateTime.now(), paused: !s.playing || s.completed)) {
        t.cancel();
        onStall();
      }
    });
  }

  void _noSignal(Channel c) {
    message = 'NO SIGNAL';
    notifyListeners();
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 30), () => _safeTune(c));
  }

  /// Joins [c] as it airs now. If the file can't be opened, moves on to the next slot.
  Future<void> tune(Channel c, {int attempt = 0}) async {
    final gen = ++_generation;
    _slotTimer?.cancel();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    channel = c;
    onDemand = null;
    onDemandEnded = false;
    _live = null;
    standBy = true;
    message = null;
    notifyListeners();
    try {
      await _tune(c, gen, attempt);
    } on Object catch (e) {
      log('tune ${c.number} error: $e');
      if (gen == _generation) _noSignal(c);
    }
  }

  Future<void> _tune(Channel c, int gen, int attempt) async {
    await engine.ensurePool(c);
    final a = engine.airing(c, DateTime.now());
    if (gen != _generation) return;
    if (a == null && c.type == 'weatherstar') {
      // Weather without music: nothing to play, the weather screens are the picture.
      airing = null;
      await player.stop();
      notifyListeners();
      return;
    }
    if (a == null) {
      airing = null;
      message = 'OFF AIR';
      notifyListeners();
      return;
    }
    airing = a;
    notifyListeners();

    final resolveSw = Stopwatch()..start();
    final url = await resolveUrl(a.slot.entry.url);
    final resolveMs = resolveSw.elapsedMilliseconds;
    if (gen != _generation) return;

    final sw = Stopwatch()..start();
    try {
      await _openAt(url, Duration(milliseconds: (a.offsetSeconds * 1000).round()));
      if (gen != _generation) return;
      if (await _captionsFor(engine.fresh(c, a.slot.entry), archive: c.type == 'archive') == 'missing') {
        // Foreign with no English subtitles: never again (saved), and on to whatever airs instead.
        engine.markNoSubs(c, a.slot.entry.id);
        await player.stop(); // nothing must keep playing behind STAND BY / OFF AIR
        if (gen == _generation) await tune(c, attempt: attempt);
        return;
      }
      if (gen != _generation) return;
      tuneTimes.insert(0, sw.elapsedMilliseconds);
      if (tuneTimes.length > 50) tuneTimes.removeLast();
      log('tune ${c.number} ${c.name}: first frame in ${sw.elapsedMilliseconds} ms after open (resolve $resolveMs ms) (${a.slot.entry.title} @ ${a.offsetSeconds.round()}s)');
      standBy = false;
      notifyListeners();
      _slotTimer = Timer(a.slot.end.difference(DateTime.now()), () => _safeTune(c));
      // A stall counts as a failed first try: re-resolve and rejoin; if that fails too, the item is skipped.
      _watchStall(gen, () {
        log('tune ${c.number}: playback stalled (${a.slot.entry.id}), retrying');
        _direct.remove(a.slot.entry.url);
        _safeTune(c, attempt: 1);
      });
    } on Object catch (e) {
      log('tune ${c.number} failed: $e');
      if (gen != _generation) return;
      // Attempts go: even = first try of an item, odd = its retry. Two items get tried, then NO SIGNAL.
      if (attempt >= 4) {
        _noSignal(c);
        return;
      }
      if (attempt.isEven) {
        _direct.remove(a.slot.entry.url); // the cached redirect may be stale: re-resolve once
      } else {
        engine.markBad(c, a.slot.entry.id); // failed twice: skip it, the next tune lands on another item
      }
      // Keep STAND BY up while retrying.
      await Future<void>.delayed(const Duration(seconds: 1));
      if (gen != _generation) return; // the viewer flipped away; don't pull them back
      await tune(c, attempt: attempt + 1);
    }
  }

  /// Opens [url] at [start] and returns on the first frame; throws if the server refuses
  /// the file or nothing plays within 15 s.
  Future<void> _openAt(String url, Duration start) async {
    final firstFrame = Completer<void>();
    // Position events left over from the previous file must not count as the first frame:
    // only a position in [start, start + 5 s], seen after open() returned, does.
    var armed = false;
    final sub = player.stream.position.listen((pos) {
      if (armed && !firstFrame.isCompleted && pos > start && pos < start + const Duration(seconds: 5)) {
        firstFrame.complete();
      }
    });
    // A file the server refuses (401/403/404) fails now instead of after the 15 s timeout.
    final errSub = player.stream.error.listen((e) {
      if (!firstFrame.isCompleted && (e.contains('Failed to open') || e.contains('HTTP error'))) {
        firstFrame.completeError(StateError(e));
      }
    });
    try {
      captionState = 'off';
      _captioned = null;
      await resetCaptions(mpv).catchError((Object e) => log('captions reset failed: $e'));
      await player.open(Media(url, start: start), play: true);
      armed = true;
      await firstFrame.future.timeout(const Duration(seconds: 15));
    } finally {
      await sub.cancel();
      await errSub.cancel();
    }
  }

  /// The title playing On Demand (null while watching live), and the live channel to go back to.
  Entry? onDemand;
  Channel? _live;

  /// True once the On Demand title has played to its end (the screen offers the next episode).
  bool onDemandEnded = false;

  /// Plays [e] from [from] (default the start) outside the live schedule.
  Future<void> playOnDemand(Channel c, Entry e, {Duration from = Duration.zero}) async {
    final gen = ++_generation;
    _slotTimer?.cancel();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    if (onDemand == null) _live = channel;
    channel = c;
    airing = null;
    onDemand = e;
    onDemandEnded = false;
    standBy = true;
    message = null;
    notifyListeners();
    try {
      await _openAt(await resolveUrl(e.url), from);
      if (gen != _generation) return;
      if (await _captionsFor(e, archive: c.type == 'archive') == 'missing') {
        engine.markNoSubs(c, e.id);
        await player.stop();
        message = 'NO ENGLISH SUBTITLES';
        notifyListeners();
        return;
      }
      if (gen != _generation) return;
      log('on demand ${c.name}: ${e.id} from ${from.inSeconds}s');
      standBy = false;
      notifyListeners();
      _watchStall(gen, () {
        log('on demand ${e.id}: playback stalled, reopening');
        _direct.remove(e.url);
        unawaited(playOnDemand(c, e, from: player.state.position));
      });
    } on Object catch (err) {
      log('on demand ${e.id} failed: $err');
      if (gen != _generation) return;
      message = 'NO SIGNAL';
      notifyListeners();
    }
  }

  /// Leaves On Demand and rejoins the live channel it was started from, as it airs now.
  void returnToLive() {
    final c = _live ?? channel;
    if (c != null) _safeTune(c);
  }

  void togglePause() => unawaited(player.playOrPause());

  Duration? _seekTo;
  DateTime _seekAt = DateTime(0);

  /// Skips by [d]; quick repeated presses add up even before the player reports the new position.
  void seekBy(Duration d) {
    final now = DateTime.now();
    final from = _seekTo != null && now.difference(_seekAt) < const Duration(seconds: 2) ? _seekTo! : player.state.position;
    var to = from + d;
    if (to < Duration.zero) to = Duration.zero;
    _seekTo = to;
    _seekAt = now;
    unawaited(player.seek(to));
  }

  final Map<String, String> _direct = {};
  final http.Client _http = http.Client();

  /// Archive answers /download/... with a redirect to a storage server. Following it once
  /// ahead of time (and remembering it) lets the player connect straight to that server.
  Future<String> resolveUrl(String url) async {
    final cached = _direct[url];
    if (cached != null) return cached;
    try {
      final req = http.Request('HEAD', Uri.parse(url))..followRedirects = false;
      final res = await _http.send(req).timeout(const Duration(seconds: 8));
      final loc = res.headers['location'];
      final direct = (res.statusCode >= 300 && res.statusCode < 400 && loc != null) ? Uri.parse(url).resolve(loc).toString() : url;
      return _direct[url] = direct;
    } on Object {
      return url; // fall back to the original address; the player will follow the redirect itself
    }
  }

  /// Guide warm-up: resolve the airing file of [c] without starting playback.
  Future<void> warm(Channel c) async {
    await engine.ensurePool(c);
    final a = engine.airing(c, DateTime.now());
    if (a != null) await resolveUrl(a.slot.entry.url);
  }

  /// Re-tunes if the slot being shown has already ended (e.g. the machine slept past it).
  void retuneIfStale() {
    final c = channel, a = airing;
    if (c != null && a != null && !DateTime.now().isBefore(a.slot.end)) _safeTune(c);
  }

  /// Turns on the captions [e] should have (see [applyCaptions]) once it is open; logs the choice.
  Future<CaptionState> _captionsFor(Entry e, {required bool archive}) async {
    _captioned = e;
    _forceForeign = archive;
    try {
      final native = player.platform;
      final tracks = native is NativePlayer ? parseSubTracks(await native.getProperty('track-list')) : const <SubTrack>[];
      captionState = await applyCaptions(mpv, e, tracks, captionsOn: captionsOn, forceForeign: archive);
      if (e.foreign || captionState != 'off') {
        log('captions $captionState for ${e.id} (language ${e.language ?? '-'}, sidecar ${e.subUrl != null}, '
            '${tracks.length} sub tracks)');
      }
    } on Object catch (err) {
      log('captions for ${e.id} failed: $err');
      captionState = 'off';
    }
    return captionState;
  }

  /// The CC switch: applies at once to the file on screen.
  Future<void> setCaptions(bool on) async {
    if (on == captionsOn) return;
    captionsOn = on;
    final e = _captioned;
    if (e != null && !standBy) {
      await _captionsFor(e, archive: _forceForeign);
      notifyListeners();
    }
  }

  void setVolume(double v) => player.setVolume(v.clamp(0, 100));

  String? _leveling;

  /// False once libmpv has shown it can't build the leveling filters (the menu then says so).
  bool levelingAvailable = true;

  /// [reopen]: the chain failed while audio started, and mpv then plays that file without sound;
  /// clear the filters and reopen what was playing so the sound comes back.
  Future<void> _levelingUnavailable({bool reopen = false}) async {
    levelingAvailable = false;
    log('volume leveling: filters not available in this libmpv, playing unfiltered${reopen ? ' (reopening)' : ''}');
    final native = player.platform;
    if (native is NativePlayer) await native.setProperty('af', '').catchError((Object _) {});
    notifyListeners();
    if (!reopen) return;
    final c = channel, od = onDemand;
    if (c == null) return;
    if (od != null) {
      unawaited(playOnDemand(c, od, from: player.state.position));
    } else {
      _safeTune(c);
    }
  }

  /// Volume leveling through mpv's audio filter chain (one setting for live, On Demand and weather music).
  /// If this libmpv can't build the filter, mpv keeps the old chain: we log it and clear the chain, so
  /// sound always plays, unfiltered at worst.
  Future<void> setLeveling(String mode) async {
    if (mode == _leveling) return; // re-setting af restarts the audio chain: only on a real change
    _leveling = mode;
    final native = player.platform;
    if (native is! NativePlayer || !levelingAvailable) return;
    final af = levelingFilter(mode);
    try {
      await native.setProperty('af', af);
      final got = await native.getProperty('af');
      if (af.isNotEmpty && !got.contains(af.contains('alimiter') ? 'alimiter' : 'dynaudnorm')) {
        await _levelingUnavailable();
      } else {
        log('volume leveling $mode (af="$got")');
      }
    } on Object catch (e) {
      log('volume leveling $mode failed: $e');
    }
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _logSub?.cancel();
    _slotTimer?.cancel();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _http.close();
    player.dispose();
    super.dispose();
  }
}
