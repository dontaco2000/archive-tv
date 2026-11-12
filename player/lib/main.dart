import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'engine/tv_engine.dart';
import 'input/gamepad.dart';
import 'player/player_controller.dart';
import 'remote/remote_server.dart';
import 'settings/crash_log.dart';
import 'settings/rotating_log.dart';
import 'settings/settings_file.dart';
import 'settings/settings_store.dart';
import 'settings/window_prefs.dart';
import 'ui/tv_screen.dart';
import 'ui/weather_web.dart';

CrashLog? _crash;

/// Any uncaught Dart error: into archive_tv.log with its stack (and kept as the menu's last error).
void _uncaught(String where, Object e, StackTrace? st) {
  final c = _crash;
  if (c != null) {
    c.error(where, e, st);
  } else {
    debugPrint('uncaught ($where): $e\n$st');
  }
}

void main(List<String> args) {
  // The whole app runs in this zone, so async errors nobody awaited land in the log too.
  runZonedGuarded(() => _main(args), (e, st) => _uncaught('zone', e, st));
}

Future<void> _main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // Fire TV sticks have 1 GB: decoded images (channel logos) stay under 24 MB instead of Flutter's 100 MB.
  if (Platform.isAndroid) PaintingBinding.instance.imageCache.maximumSizeBytes = 24 << 20;
  FlutterError.onError = (d) {
    FlutterError.presentError(d);
    _uncaught('flutter', d.exception, d.stack);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    _uncaught('platform', e, st);
    return true;
  };
  MediaKit.ensureInitialized();
  // Android TV / Fire TV: always fullscreen landscape, no window to manage.
  final desktop = !Platform.isAndroid;
  if (desktop) {
    await windowManager.ensureInitialized();
  } else {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  // Test switches: --data-dir=<folder> (use a copy instead of the real data folder), --channel=<n> (start there).
  String? arg(String name) => args.where((a) => a.startsWith('--$name=')).map((a) => a.substring(name.length + 3)).firstOrNull;
  final dataDir = Directory(arg('data-dir') ?? p.join((await getApplicationSupportDirectory()).path, 'ArchiveTV'))
    ..createSync(recursive: true);
  final logFile = RotatingLog(File(p.join(dataDir.path, 'archive_tv.log'))); // 2 MB, keeps .1 and .2
  void log(String m) {
    final line = '${DateTime.now().toIso8601String()} $m';
    debugPrint(line);
    try {
      logFile.write(line);
    } on FileSystemException {
      // logging must never take the app down
    }
  }
  final crash = _crash = CrashLog(dataDir, log)..start(logFile.file);
  // Android has no window to close: a run that went to the background (or was left with Back) ended cleanly.
  if (Platform.isAndroid) {
    AppLifecycleListener(onStateChange: (s) => crash.running(s == AppLifecycleState.resumed || s == AppLifecycleState.inactive));
  }

  await initWebView(windows: Platform.isWindows, dataDir: p.join(dataDir.path, 'webview2'), log: log);

  final store = SettingsStore(File(p.join(dataDir.path, 'settings.json')));
  final settings = store.load();
  // archive_tv_settings.txt: easy settings + the one-shot parental reset; the save writes it back (reset=false, defaults on first run).
  store
    ..textFile = await settingsFileFor(dataDir, external: Platform.isAndroid && arg('data-dir') == null)
    ..log = log;
  applySettingsFile(store.textFile!, settings, log);
  try {
    store.save(settings);
  } on Object catch (e) {
    log('settings save failed: $e');
  }
  WindowPrefs? windowPrefs;
  if (desktop) {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(960, 720), minimumSize: Size(640, 480), center: true, title: 'Archive TV'),
      () async {
        await WindowPrefs.restoreBounds(settings).catchError((Object e) => log('window restore failed: $e'));
        await windowManager.show();
        if (settings.startFullscreen || settings.fullscreen) await windowManager.setFullScreen(true);
      },
    );
    windowPrefs = WindowPrefs(settings, store, log)
      ..onClose = (() => crash.running(false))
      ..attach();
    // Windowed mode keeps a 4:3 client area (the title bar is not part of the picture).
    unawaited(Future<void>.delayed(const Duration(milliseconds: 300), windowPrefs.snapToFourThree));
  }

  final configFile = File(p.join(dataDir.path, 'channels.json'));
  // The bundled config seeds the data folder; the copy there is the user's to edit. A copy nobody
  // edited (still equal to the bundle it was seeded from) follows app updates, the old one kept as .bak.
  final seededFile = File(p.join(dataDir.path, 'channels.bundled.json'));
  final bundled = await rootBundle.loadString('assets/channels.json');
  if (!configFile.existsSync()) {
    configFile.writeAsStringSync(bundled);
  } else {
    final current = configFile.readAsStringSync();
    // ponytail: installs from before 0.2 have no channels.bundled.json, so their copy is taken as unedited (backed up).
    if (current != bundled && (!seededFile.existsSync() || seededFile.readAsStringSync() == current)) {
      configFile.copySync('${configFile.path}.bak');
      configFile.writeAsStringSync(bundled);
      log('channels.json updated to the bundled version (old copy: channels.json.bak)');
    }
  }
  seededFile.writeAsStringSync(bundled);

  // Android: pools built on the PC ship in the APK, so a first launch has a full guide without building.
  if (Platform.isAndroid) {
    try {
      final sw = Stopwatch()..start();
      final gz = (await rootBundle.load('assets/seed_pools.jsonl.gz')).buffer.asUint8List();
      final n = await installSeed(Stream.value(gz), Directory(p.join(dataDir.path, 'pools')));
      if (n > 0) log('seeded $n channel pools in ${sw.elapsedMilliseconds} ms');
    } on Object catch (e) {
      log('seed pools: $e');
    }
  }

  final TvEngine engine;
  try {
    engine = TvEngine.open(
        configText: configFile.readAsStringSync(),
        dataDir: dataDir,
        probeClient: http.Client(),
        log: log,
        buildConcurrency: Platform.isAndroid ? 2 : 4);
  } on Object catch (e) {
    log('channels.json error: $e');
    runApp(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ErrorScreen(message: 'Cannot read channels.json\n\n${e is ConfigException ? e.message : e}\n\n${configFile.path}')));
    return;
  }
  final tv = PlayerController(engine, log: log)..isLocked = ((c) => settings.parental.isLocked(c.number));
  tv.setVolume(settings.muted ? 0 : settings.volume);
  unawaited(tv.setLeveling(settings.volumeLeveling));
  tv.captionsOn = settings.captionsOn;
  tv.audioDelayFor = (id) => settings.audioDelays[id] ?? 0;
  unawaited(tv.setPicture(settings.picture));
  // Remote control window (Windows only): a local web page that presses the same keys as the keyboard.
  RemoteServer? remote;
  if (Platform.isWindows) {
    remote = RemoteServer(settings, log: log);
    if (remote.ensurePin()) store.save(settings);
    await remote.start().catchError((Object e) => log('remote: start failed: $e'));
  }
  // The remote's POWER button closes the TV window like its X: onClose below, then the app ends.
  remote?.power = () => unawaited(windowManager.close());
  windowPrefs?.onClose = () {
    remote?.closeWindowOnExit();
    crash.running(false);
  };
  runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: TvScreen(controller: tv, settings: settings, store: store, windowPrefs: windowPrefs, remote: remote, crash: crash)));
  installGamepad(log: log); // pads act as the keyboard: XInput on Windows, button keys on Android
  if (args.contains('--remote') && remote != null) {
    // After the TV window has its restored bounds / fullscreen, so the remote lands beside it.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 1500), remote.openWindow));
  }

  // Remember the channel being watched so the next launch starts there.
  tv.addListener(() {
    final n = tv.channel?.number;
    if (n == null || n == settings.lastChannel) return;
    settings.lastChannel = n;
    try {
      store.save(settings);
    } on Object catch (e) {
      log('settings save failed: $e');
    }
  });
  bool isTunable(Channel c) => engine.tunable.any((t) => t.number == c.number);
  final startAt = int.tryParse(arg('channel') ?? '') ?? settings.lastChannel;
  final last = startAt == null ? null : engine.config.channel(startAt);
  // A 1 GB Android TV stick can't start on the weather page while pools build: start on the first channel instead.
  if (last != null && !tv.isLocked(last) && !(Platform.isAndroid && last.type == 'weatherstar' && arg('channel') == null)) {
    await engine.ensurePool(last);
    if (isTunable(last)) unawaited(tv.tune(last));
  }

  // Load saved pools first (seconds, however old: stale ones are rebuilt behind them by the refresh below),
  // then build the channels that have none, one at a time; start on the first channel that has content,
  // but never override a channel the viewer already picked.
  final saved = [for (final c in engine.channels) if (engine.pools.age(c.number) != null) c];
  for (final c in [...saved, ...engine.channels.where((c) => !saved.contains(c))]) {
    await engine.ensurePool(c);
    engine.planWeek(c, DateTime.now());
    final open = engine.tunable.where((c) => !tv.isLocked(c)).firstOrNull; // never start on a locked channel
    if (tv.channel == null && open != null) unawaited(tv.tune(open));
  }
  final first = engine.tunable;

  // Midnight: refresh day-old pools, save the new week, probe the new day, stay on the right slot.
  // Checked once a minute (not one long timer) so sleep/hibernate and DST can't make it miss.
  var today = dayKey(DateTime.now());
  var refreshing = false;
  // Stale pools were loaded as they are; this rebuilds them in the background (Android: waits while a video starts).
  bool busy() => tv.standBy && tv.message == null;
  Future<void> refresh(DateTime now) async {
    refreshing = true;
    try {
      await engine.dailyRefresh(now, busy: Platform.isAndroid ? busy : null);
    } finally {
      refreshing = false;
    }
  }

  Timer.periodic(const Duration(minutes: 1), (_) async {
    final now = DateTime.now();
    if (dayKey(now) == today || refreshing) return;
    today = dayKey(now);
    log('new day $today: daily refresh');
    tv.retuneIfStale();
    await refresh(now);
  });
  unawaited(refresh(DateTime.now()));

  // `--latency-test`: flip through the channels a few times, log first-frame times, then quit.
  if (args.contains('--latency-test')) {
    // Round 0 is cold (nothing resolved). Round 1 warms every channel first, like the guide does.
    for (final c in first) {
      await tv.tune(c);
    }
    for (final c in first) {
      await tv.warm(c);
    }
    for (var round = 0; round < 2; round++) {
      for (final c in first) {
        await tv.tune(c);
      }
    }
    log('latency test done: ${tv.tuneTimes.reversed.toList()} ms');
    crash.running(false);
    exit(0);
  }
}
