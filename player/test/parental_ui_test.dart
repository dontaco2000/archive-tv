import 'dart:convert';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/guide/guide_model.dart';
import 'package:archive_tv_player/input/actions.dart';
import 'package:archive_tv_player/parental/parental.dart';
import 'package:archive_tv_player/parental/parental_flow.dart';
import 'package:archive_tv_player/parental/parental_ui.dart';
import 'package:archive_tv_player/remote/remote_server.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/guide_overlay.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Slot slot(String title, DateTime start, int minutes) => Slot(
      Entry(id: title, itemId: title, file: '$title.mp4', title: title, durationSeconds: minutes * 60.0, url: 'u'),
      start,
      start.add(Duration(minutes: minutes)),
    );

void main() {
  final now = DateTime(2026, 11, 11, 10, 15);
  const a = Channel(number: 1, name: 'Alpha', genre: 'Movies');
  const b = Channel(number: 25, name: 'Headliner', genre: 'TV', mature: true);
  const c = Channel(number: 3, name: 'Charlie');

  Parental locked25() => Parental()
    ..setPin('1234')
    ..lockOn = true
    ..locked = {25};

  test('Channel Up/Down skip locked channels (and On Demand gets only open ones)', () {
    final p = locked25();
    final open = p.openChannels([a, b, c]);
    expect(open, [a, c]);
    expect(flipTarget(open, 1, 1), c); // 1 -> 3, skipping 25
    expect(flipTarget(open, 3, 1), a);
    p.lockOn = false;
    expect(p.openChannels([a, b, c]), [a, b, c]);
  });

  GuideModel guide(Set<int> locked) => GuideModel(
        channels: const [a, b, c],
        now: now,
        tunableNumbers: {1, 25, 3},
        lockedNumbers: locked,
        horizon: now.add(const Duration(days: 1)),
        slotsFor: (ch) => [slot('${ch.name} Show', DateTime(2026, 11, 11, 10), 120)],
      );

  test('guide model: a locked row is one LOCKED cell, no titles, still selectable to tune', () {
    final m = guide({25});
    final rows = m.rowsInView(3);
    expect(rows[1].cells.single.label, lockedLabel);
    expect(rows[1].cells.single.slot, isNull);
    expect(rows[1].tunable, true);
    m.moveRow(1);
    expect(m.selectedSlot, isNull);
    m.moveProgram(1); // no programmes to walk: moves time only, no crash
    expect(rows[0].cells.single.label, 'Alpha Show');
  });

  testWidgets('guide overlay: lock marker and LOCKED, the title never shown', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: GuideOverlay(model: guide({25})..moveRow(1), onTune: (_) {}, onHighlight: (_) {}, onClose: () {})),
    ));
    await t.pump();
    expect(find.text('LOCKED'), findsOneWidget);
    expect(find.textContaining('Headliner Show'), findsNothing);
    expect(find.text('$lockMarker${25} '), findsOneWidget);
    expect(find.text('${1} '), findsOneWidget); // open channels have no marker
  });

  Future<(List<String>, List<int>)> pumpPrompt(WidgetTester t) async {
    final pins = <String>[], cancels = <int>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: PinPrompt(request: PinRequest('Test', pins.add), onCancel: () => cancels.add(1))),
    ));
    await t.pump();
    return (pins, cancels);
  }

  testWidgets('PIN prompt: number keys type four digits and submit', (t) async {
    final (pins, _) = await pumpPrompt(t);
    for (final k in [LogicalKeyboardKey.digit2, LogicalKeyboardKey.numpad4, LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit8]) {
      await t.sendKeyEvent(k);
    }
    expect(pins, ['2468']);
  });

  testWidgets('PIN prompt: D-pad picker (Fire TV remote) Up/Down + Right/OK', (t) async {
    final (pins, _) = await pumpPrompt(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp); // 1
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 9
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight); // 0
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft); // back to the third digit
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp); // 1
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pump();
    expect(find.text('0'), findsOneWidget); // the digit under the cursor is shown, the rest masked
    expect(find.text('*'), findsNWidgets(3));
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.sendKeyEvent(LogicalKeyboardKey.select); // 2
    expect(pins, ['1912']);
  });

  testWidgets('PIN prompt: Esc cancels; other keys do not reach the TV', (t) async {
    final (pins, cancels) = await pumpPrompt(t);
    expect(await t.sendKeyEvent(LogicalKeyboardKey.keyG), true); // handled (swallowed)
    expect(await t.sendKeyEvent(LogicalKeyboardKey.equal), false); // volume passes through
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(cancels, [1]);
    expect(pins, isEmpty);
  });

  test('parental screen rows: no PIN / lock ON (list read-only) / lock OFF (list editable)', () {
    final p = Parental();
    final flashes = <String>[];
    final flow = ParentalFlow(p, save: () {}, flash: flashes.add, ask: (_) {});
    List<String> labels() => [for (final r in parentalRows(p, const [a, b, c], flow, () {}, () {})) r.$1];
    expect(labels(), ['Set PIN', 'Late night adult mode: ON', 'Close']);
    p
      ..setPin('1234')
      ..lockOn = true;
    expect(labels(), contains('Parental lock: ON (Enter + PIN: turn OFF)'));
    expect(labels().where((l) => l.startsWith('25 ')), isEmpty);
    p.lockOn = false;
    final rows = parentalRows(p, const [a, b, c], flow, () {}, () {});
    expect(rows.first.$1, 'Parental lock: OFF (Enter: turn ON)');
    rows.firstWhere((r) => r.$1 == 'Lock mature channels').$2!();
    expect(p.locked, {25});
    expect(flashes.last, 'Locked 1 mature channels');
    expect(labels(), contains('25 Headliner (mature): LOCKED'));
    expect(labels(), contains('1 Alpha: open'));
    parentalRows(p, const [a, b, c], flow, () {}, () {}).firstWhere((r) => r.$1 == '1 Alpha: open').$2!();
    expect(p.locked, {1, 25});
  });

  testWidgets('menu has Parental controls and (when given) Open settings file', (t) async {
    final calls = <String>[];
    final s = Settings()..parental = locked25();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 2000,
          child: MenuOverlay(
            settings: s,
            current: null,
            onChanged: (_) {},
            onBlockCurrent: () {},
            onRefresh: () {},
            onClose: () {},
            onParental: () => calls.add('parental'),
            onOpenSettingsFile: () => calls.add('file'),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Parental controls: LOCK ON'), findsOneWidget); // on the top level
    for (var i = 0; i < 3; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown); // to Sleep & Tools (no remote here)
    }
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(find.text('Open settings file'), findsOneWidget);
  });

  group('remote', () {
    late List<String> pins;
    late RemoteServer server;
    const post = {'host': '127.0.0.1:8765', 'x-remote': '1'};
    setUp(() {
      pins = [];
      server = RemoteServer(Settings())
        ..parentalPin = pins.add
        ..state = (() => {'pinPrompt': {'id': 1, 'title': '25 HEADLINER is locked', 'hint': null}});
    });

    test('POST /api/parental answers the TV prompt; only 4 digits accepted', () async {
      var r = await server.handle('POST', '/api/parental', post, jsonEncode({'pin': '1234'}), loopback: true);
      expect(r.$1, 200);
      r = await server.handle('POST', '/api/parental', post, jsonEncode({'pin': '12'}), loopback: true);
      expect(r.$1, 400);
      r = await server.handle('POST', '/api/parental', post, jsonEncode({'pin': 1234}), loopback: true);
      expect(r.$1, 400);
      expect(pins, ['1234']);
    });

    test('/api/state carries the prompt; the page knows how to answer it', () async {
      final r = await server.handle('GET', '/api/state', const {'host': '127.0.0.1:8765'}, '', loopback: true);
      expect((jsonDecode(r.$3 as String) as Map)['pinPrompt']['title'], contains('locked'));
      final page = (await server.handle('GET', '/remote', const {'host': '127.0.0.1:8765'}, '', loopback: true)).$3 as String;
      expect(page, contains("send('/api/parental'"));
      expect(page, contains('s.pinPrompt'));
    });
  });
}
