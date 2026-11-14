// On Demand navigation: genres -> shows -> episodes, search, the rated rule. Screenshots of every level at TV and
// phone size when ONDEMAND_SHOTS names a folder:
//   $env:ONDEMAND_SHOTS='D:\Claude Projects\Archive TV\_build\screens'; flutter test test/on_demand_overlay_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/ui/on_demand_overlay.dart';
import 'package:archive_tv_player/ui/touch.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Entry _e(String item, String title, {int minutes = 25}) =>
    Entry(id: '$item/$title.mp4', itemId: item, file: '$title.mp4', title: title, durationSeconds: minutes * 60.0, url: 'u');

const funnies = Channel(number: 2, name: 'Funnies', genre: 'Kids & Animation');
const capes = Channel(number: 3, name: 'Capes', genre: 'Kids & Animation');
const haunt = Channel(number: 14, name: 'Haunt', genre: 'Movies');
const lens = Channel(number: 42, name: 'Lens', genre: 'News & Docs');

final gargoyles3 = _e('garg', 'Gargoyles S01E03 Awakening Part 3');
final film = _e('dotd', 'Dawn of the Dead (1978)', minutes: 127);
final pools = {
  2: [_e('garg', 'Gargoyles S01E02 Awakening Part 2'), gargoyles3, _e('tex', 'Tex Avery - Bad Luck Blackie', minutes: 7), _e('tex', 'Tex Avery - Droopy', minutes: 7)],
  // the same show on a second channel of the genre merges; an id on both channels shows once
  3: [_e('garg2', 'Gargoyles - S02E01 - Leader of the Pack'), gargoyles3, _e('bat', 'Batman The Animated Series S01E01 On Leather Wings')],
  14: [film, _e('nld', 'Night of the Living Dead (1968)', minutes: 96), _e('hitch', 'Alfred Hitchcock Presents S01E01'), _e('hitch', 'Alfred Hitchcock Presents S01E02')],
  42: [_e('cosmos', 'Cosmos 01 The Shores of the Cosmic Ocean', minutes: 60), _e('cosmos', 'Cosmos 02 One Voice in the Cosmic Fugue', minutes: 60)],
};

void main() {
  final out = Platform.environment['ONDEMAND_SHOTS'];
  var adultMode = true;
  setUp(() => adultMode = true);

  setUpAll(() async {
    for (final f in [r'C:\Windows\Fonts\consola.ttf', r'C:\Windows\Fonts\consolab.ttf']) {
      if (File(f).existsSync()) {
        final loader = FontLoader('Consolas')..addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
        await loader.load();
      }
    }
  });

  final boundary = GlobalKey();
  Future<List<(Channel, Entry)>> pump(WidgetTester t, {List<String>? closed, bool text = true, bool touch = false, Size size = const Size(960, 540)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final played = <(Channel, Entry)>[];
    // As the engine does: adult mode OFF leaves rated entries out of the pools; ON tags them.
    List<Entry> pool(Channel c) => [for (final e in pools[c.number]!) if (adultMode || e != film) e];
    Widget overlay = OnDemandOverlay(
      key: UniqueKey(), // a fresh overlay (and genre cache) per pump, as each opening is
      channels: const [funnies, capes, haunt, lens],
      poolOf: pool,
      isRated: (c, e) => adultMode && e == film,
      onPlay: (c, e) => played.add((c, e)),
      onClose: () => closed?.add('closed'),
      textSearch: text,
    );
    if (touch) overlay = TouchUi(child: overlay);
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(child: RepaintBoundary(key: boundary, child: overlay)),
    ));
    await t.pump();
    return played;
  }

  Future<void> key(WidgetTester t, LogicalKeyboardKey k, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await t.sendKeyEvent(k);
    }
    await t.pump(); // "Loading shows..." frame
    await t.pump();
  }

  Future<void> shot(WidgetTester t, String name) async {
    if (out == null) return;
    await t.runAsync(() async {
      final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await (await ro.toImage()).toByteData(format: ui.ImageByteFormat.png);
      File('$out${Platform.pathSeparator}ondemand-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  testWidgets('genre -> shows (channels merged) -> episodes -> play; Back walks up keeping the place', (t) async {
    final closed = <String>[];
    final played = await pump(t, closed: closed);
    expect(find.text(searchLabel), findsOneWidget);
    expect(find.text('Kids & Animation'), findsOneWidget);
    expect(find.text('Funnies'), findsNothing); // no channel level
    await key(t, LogicalKeyboardKey.arrowDown);
    await key(t, LogicalKeyboardKey.enter); // Kids & Animation
    expect(find.text('Gargoyles'), findsOneWidget);
    expect(find.text('3 episodes'), findsOneWidget); // S01E02, S01E03 (on two channels, once), S02E01
    expect(find.text('Tex Avery'), findsOneWidget);
    expect(find.text(specialsLabel), findsOneWidget); // Batman's single episode
    await key(t, LogicalKeyboardKey.arrowDown); // Gargoyles (after Batman? no: Batman is a single)
    await key(t, LogicalKeyboardKey.arrowUp);
    await key(t, LogicalKeyboardKey.enter);
    expect(find.textContaining('S01E02 Awakening Part 2'), findsOneWidget);
    expect(find.textContaining('S02E01'), findsOneWidget);
    await key(t, LogicalKeyboardKey.arrowDown, 2);
    await key(t, LogicalKeyboardKey.enter);
    expect(played.single.$1, capes);
    expect(played.single.$2.title, contains('S02E01'));
    await key(t, LogicalKeyboardKey.escape);
    expect(find.text('Tex Avery'), findsOneWidget); // back on the shows
    await key(t, LogicalKeyboardKey.escape);
    expect(find.text(searchLabel), findsOneWidget);
    await key(t, LogicalKeyboardKey.escape);
    expect(closed, ['closed']);
  });

  testWidgets('rated: tagged R and listed when adult mode is ON, gone when OFF', (t) async {
    await pump(t);
    await key(t, LogicalKeyboardKey.arrowDown, 2);
    await key(t, LogicalKeyboardKey.enter); // Movies
    expect(find.text(specialsLabel), findsOneWidget);
    expect(find.text('2 titles'), findsOneWidget);
    await key(t, LogicalKeyboardKey.arrowDown);
    await key(t, LogicalKeyboardKey.enter);
    expect(find.text('Dawn of the Dead (1978)'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);

    adultMode = false;
    await pump(t);
    await key(t, LogicalKeyboardKey.arrowDown, 2);
    await key(t, LogicalKeyboardKey.enter);
    await key(t, LogicalKeyboardKey.arrowDown);
    await key(t, LogicalKeyboardKey.enter);
    expect(find.text('Dawn of the Dead (1978)'), findsNothing);
    expect(find.text('R'), findsNothing);
  });

  testWidgets('text search: show names first, then episodes; a show opens its episodes', (t) async {
    final played = await pump(t);
    await key(t, LogicalKeyboardKey.enter); // SEARCH
    await t.enterText(find.byType(TextField), 'g');
    await t.pump();
    expect(find.text('Type at least 2 letters'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'garg');
    await t.pump();
    expect(find.text('Gargoyles  (3 episodes)'), findsOneWidget);
    expect(find.text('Gargoyles S01E02 Awakening Part 2'), findsOneWidget);
    await key(t, LogicalKeyboardKey.arrowDown); // into the results
    await key(t, LogicalKeyboardKey.enter); // the show
    expect(find.textContaining('S02E01'), findsOneWidget);
    await key(t, LogicalKeyboardKey.enter);
    expect(played.single.$2.title, 'Gargoyles S01E02 Awakening Part 2');
    await key(t, LogicalKeyboardKey.escape); // back to the results
    expect(find.text('Gargoyles  (3 episodes)'), findsOneWidget);
  });

  testWidgets('typing letters in the field never reaches the TV hotkeys', (t) async {
    final keys = <LogicalKeyboardKey>[];
    await pump(t);
    // a parent like TvScreen that would swallow "m" (mute)
    final focus = FocusManager.instance.rootScope;
    focus.onKeyEvent = (n, e) {
      if (e is KeyUpEvent) return KeyEventResult.ignored; // TvScreen acts on key down / repeat only
      keys.add(e.logicalKey);
      return KeyEventResult.handled;
    };
    addTearDown(() => focus.onKeyEvent = null);
    await key(t, LogicalKeyboardKey.enter);
    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    expect(keys, isNot(contains(LogicalKeyboardKey.keyM)));
  });

  testWidgets('arcade search (TV remote) still finds shows', (t) async {
    final played = await pump(t, text: false);
    await key(t, LogicalKeyboardKey.enter); // SEARCH
    await key(t, LogicalKeyboardKey.arrowUp, 3); // C
    expect(find.text('Cosmos  (2 episodes)'), findsOneWidget);
    await key(t, LogicalKeyboardKey.enter); // to the results
    await key(t, LogicalKeyboardKey.enter); // open Cosmos
    await key(t, LogicalKeyboardKey.enter); // play
    expect(played.single.$1, lens);
  });

  testWidgets('touch: tapping rows opens and plays', (t) async {
    final played = await pump(t, touch: true, size: const Size(390, 700));
    await t.tap(find.text('Movies'));
    await t.pump();
    await t.pump();
    await t.tap(find.text('Alfred Hitchcock Presents'));
    await t.pump();
    await t.tap(find.text('S01E02'));
    expect(played.single.$1, haunt);
  });

  for (final (name, size) in [('tv', const Size(1920, 1080)), ('phone', const Size(390, 780))]) {
    testWidgets('screenshots $name', (t) async {
      await pump(t, size: size, touch: name == 'phone');
      await shot(t, '$name-1-genres');
      await key(t, LogicalKeyboardKey.arrowDown);
      await key(t, LogicalKeyboardKey.enter);
      await shot(t, '$name-2-shows');
      await key(t, LogicalKeyboardKey.enter);
      await shot(t, '$name-3-episodes');
      await key(t, LogicalKeyboardKey.escape, 2);
      await key(t, LogicalKeyboardKey.arrowDown);
      await key(t, LogicalKeyboardKey.enter); // Movies
      await key(t, LogicalKeyboardKey.arrowDown);
      await key(t, LogicalKeyboardKey.enter);
      await shot(t, '$name-4-specials-rated');
      await key(t, LogicalKeyboardKey.escape, 2);
      await key(t, LogicalKeyboardKey.arrowUp, 2);
      await key(t, LogicalKeyboardKey.enter);
      await t.enterText(find.byType(TextField), 'gar');
      await t.pump();
      await shot(t, '$name-5-search');
      expect(t.takeException(), isNull);
    });
  }
}
