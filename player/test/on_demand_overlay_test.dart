import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/ui/on_demand_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Entry _e(String item, String title) =>
    Entry(id: '$item/f.mp4', itemId: item, file: 'f.mp4', title: title, durationSeconds: 1500, url: 'u');

void main() {
  const funnies = Channel(number: 2, name: 'Funnies');
  const byte = Channel(number: 32, name: 'Byte');
  final pools = {
    2: [_e('a', 'Alpha Show'), _e('b', 'Bravo Hour')],
    32: [_e('c', 'Beta Chronicles')],
  };

  Future<List<(Channel, Entry)>> pump(WidgetTester tester, {List<String>? closed}) async {
    final played = <(Channel, Entry)>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 600,
          child: OnDemandOverlay(
            channels: const [funnies, byte],
            poolOf: (c) => pools[c.number]!,
            onPlay: (c, e) => played.add((c, e)),
            onClose: () => closed?.add('closed'),
          ),
        ),
      ),
    ));
    await tester.pump();
    return played;
  }

  testWidgets('browse: a channel shelf lists its titles and Enter plays one', (tester) async {
    final played = await pump(tester);
    expect(find.text('SEARCH'), findsOneWidget);
    expect(find.textContaining('FUNNIES'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // Funnies
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.textContaining('Alpha Show'), findsOneWidget);
    expect(find.textContaining('Bravo Hour'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(played.single.$1.number, 2);
    expect(played.single.$2.title, 'Bravo Hour');
  });

  testWidgets('Esc steps back from titles to the shelves, then closes', (tester) async {
    final closed = <String>[];
    await pump(tester, closed: closed);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('SEARCH'), findsOneWidget);
    expect(closed, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, ['closed']);
  });

  testWidgets('arcade search narrows titles across channels as letters change', (tester) async {
    final played = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // SEARCH
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // A
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // B
    await tester.pump();
    expect(find.textContaining('Beta Chronicles'), findsOneWidget);
    expect(find.textContaining('Bravo Hour'), findsOneWidget);
    expect(find.textContaining('Alpha Show'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 9
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // 8 ... back up to R below
    for (var i = 0; i < 2 + 18; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // 9, blank, A..R
    }
    await tester.pump();
    expect(find.textContaining('Bravo Hour'), findsOneWidget);
    expect(find.textContaining('Beta Chronicles'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // confirm: go to the results
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // play the first
    expect(played.single.$2.title, 'Bravo Hour');
  });
}
