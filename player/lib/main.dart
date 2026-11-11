import 'dart:async';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'engine/tv_engine.dart';
import 'player/player_controller.dart';
import 'settings/rotating_log.dart';
import 'settings/settings_store.dart';
import 'settings/window_prefs.dart';
import 'ui/tv_screen.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
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

  final store = SettingsStore(File(p.join(dataDir.path, 'settings.json')));
  final settings = store.load();
  WindowPrefs? windowPrefs;
  if (desktop) {
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(960, 720), minimumSize: Size(640, 480), center: true, title: 'Archive TV'),
      () async {
        await windowManager.setAspectRatio(4 / 3); // windowed mode keeps the 4:3 shape
        await WindowPrefs.restoreBounds(settings).catchError((Object e) => log('window restore failed: $e'));
        await windowManager.show();
        if (settings.startFullscreen || settings.fullscreen) await windowManager.setFullScreen(true);
      },
    );
    windowPrefs = WindowPrefs(settings, store, log)..attach();
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

  final TvEngine engine;
  try {
    engine = TvEngine.open(configText: configFile.readAsStringSync(), dataDir: dataDir, probeClient: http.Client(), log: log);
  } on Object catch (e) {
    log('channels.json error: $e');
    runApp(MaterialApp(
        debugShowCheckedModeBanner: false,
        home: ErrorScreen(message: 'Cannot read channels.json\n\n${e is ConfigException ? e.message : e}\n\n${configFile.path}')));
    return;
  }
  final tv = PlayerController(engine, log: log);
  tv.setVolume(settings.muted ? 0 : settings.volume);
  runApp(MaterialApp(debugShowCheckedModeBanner: false, home: TvScreen(controller: tv, settings: settings, store: store, windowPrefs: windowPrefs)));

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
  if (last != null) {
    await engine.ensurePool(last);
    if (isTunable(last)) unawaited(tv.tune(last));
  }

  // Build pools one channel at a time; start on the first channel that has content,
  // but never override a channel the viewer already picked.
  for (final c in engine.channels) {
    await engine.ensurePool(c);
    engine.planWeek(c, DateTime.now());
    if (tv.channel == null && engine.tunable.isNotEmpty) unawaited(tv.tune(engine.tunable.first));
  }
  final first = engine.tunable;

  // Midnight: refresh day-old pools, save the new week, probe the new day, stay on the right slot.
  // Checked once a minute (not one long timer) so sleep/hibernate and DST can't make it miss.
  var today = dayKey(DateTime.now());
  var refreshing = false;
  Timer.periodic(const Duration(minutes: 1), (_) async {
    final now = DateTime.now();
    if (dayKey(now) == today || refreshing) return;
    today = dayKey(now);
    refreshing = true;
    log('new day $today: daily refresh');
    tv.retuneIfStale();
    try {
      await engine.dailyRefresh(now);
    } finally {
      refreshing = false;
    }
  });

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
    exit(0);
  }
}
