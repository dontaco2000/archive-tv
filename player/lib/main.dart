import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'engine/tv_engine.dart';
import 'player/player_controller.dart';
import 'ui/tv_screen.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(size: Size(960, 720), minimumSize: Size(640, 480), center: true, title: 'Archive TV'),
    () async {
      await windowManager.setAspectRatio(4 / 3); // windowed mode keeps the 4:3 shape
      await windowManager.show();
    },
  );

  final dataDir = Directory(p.join((await getApplicationSupportDirectory()).path, 'ArchiveTV'))..createSync(recursive: true);
  final logFile = File(p.join(dataDir.path, 'archive_tv.log'));
  void log(String m) {
    final line = '${DateTime.now().toIso8601String()} $m';
    debugPrint(line);
    logFile.writeAsStringSync('$line\n', mode: FileMode.append);
  }

  final configFile = File(p.join(dataDir.path, 'channels.json'));
  if (!configFile.existsSync()) configFile.writeAsStringSync(defaultChannelsJson);

  final engine = TvEngine.open(configText: configFile.readAsStringSync(), dataDir: dataDir, log: log);
  final tv = PlayerController(engine, log: log);
  runApp(MaterialApp(debugShowCheckedModeBanner: false, home: TvScreen(controller: tv)));

  // Start on the first channel that has content.
  for (final c in engine.channels) {
    await engine.ensurePool(c);
  }
  final first = engine.tunable;
  if (first.isNotEmpty) await tv.tune(first.first);

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

/// Used only when the user has no channels.json yet; the real file lives in the app's data folder.
const defaultChannelsJson = '''
{
  "yearRange": [1980, 2010],
  "fallbackStart": 1960,
  "minContentHours": 2,
  "blockCollections": ["adultvhs"],
  "channels": [
    {"number": 2, "name": "Bytes", "genre": "Tech", "sources": [{"collection": "computerchronicles"}]},
    {"number": 3, "name": "Funnies", "genre": "Cartoons", "sources": [{"query": "subject:(animation OR cartoon)", "minDownloads": 2000}]}
  ]
}
''';
