import 'dart:async';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../engine/tv_engine.dart';

/// Owns the single libmpv player. `tune` shows STAND BY, opens the airing file
/// at its offset, and clears STAND BY on the first frame.
class PlayerController extends ChangeNotifier {
  final TvEngine engine;
  final Player player = Player(configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024));
  late final VideoController video = VideoController(player);
  final void Function(String) log;

  Channel? channel;
  Airing? airing;
  bool standBy = true;
  String? message;

  /// Milliseconds from tune() to first frame, most recent first (for the latency test).
  final List<int> tuneTimes = [];

  int _generation = 0; // bumped on every tune so a stale open can't clear a newer STAND BY
  StreamSubscription<bool>? _completedSub;
  Timer? _stallTimer;

  PlayerController(this.engine, {void Function(String)? log}) : log = log ?? ((_) {}) {
    final native = player.platform;
    if (native is NativePlayer) {
      // Fast start: small probe, hardware decoding, modest read-ahead.
      native.setProperty('hwdec', 'auto');
      native.setProperty('demuxer-readahead-secs', '6');
      native.setProperty('cache-secs', '10');
      native.setProperty('demuxer-lavf-probesize', '262144');
      native.setProperty('demuxer-lavf-analyzeduration', '0.5');
      native.setProperty('video-aspect-override', 'no');
    }
    _completedSub = player.stream.completed.listen((done) {
      if (done && channel != null) tune(channel!);
    });
  }

  /// Joins [c] as it airs now. If the file can't be opened, moves on to the next slot.
  Future<void> tune(Channel c, {int attempt = 0}) async {
    final gen = ++_generation;
    channel = c;
    standBy = true;
    message = null;
    notifyListeners();

    await engine.ensurePool(c);
    final a = engine.airing(c, DateTime.now());
    if (gen != _generation) return;
    if (a == null) {
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
    final start = Duration(milliseconds: (a.offsetSeconds * 1000).round());
    final firstFrame = Completer<void>();
    // Position events left over from the previous channel must not count as the first frame:
    // only a position in [start, start + 5 s], seen after open() returned, does.
    var armed = false;
    final sub = player.stream.position.listen((pos) {
      if (armed && !firstFrame.isCompleted && pos > start && pos < start + const Duration(seconds: 5)) {
        firstFrame.complete();
      }
    });
    try {
      await player.open(Media(url, start: start), play: true);
      armed = true;
      await firstFrame.future.timeout(const Duration(seconds: 15));
      if (gen != _generation) return;
      tuneTimes.insert(0, sw.elapsedMilliseconds);
      log('tune ${c.number} ${c.name}: first frame in ${sw.elapsedMilliseconds} ms after open (resolve $resolveMs ms) (${a.slot.entry.title} @ ${a.offsetSeconds.round()}s)');
      standBy = false;
      notifyListeners();
    } on Object catch (e) {
      log('tune ${c.number} failed: $e');
      if (gen != _generation) return;
      if (attempt >= 2) {
        message = 'NO SIGNAL';
        notifyListeners();
        return;
      }
      // Skip to the next item at its start, keeping STAND BY up.
      await Future<void>.delayed(const Duration(seconds: 1));
      await tune(c, attempt: attempt + 1);
    } finally {
      await sub.cancel();
    }
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

  void setVolume(double v) => player.setVolume(v.clamp(0, 100));

  @override
  void dispose() {
    _completedSub?.cancel();
    _stallTimer?.cancel();
    player.dispose();
    super.dispose();
  }
}
