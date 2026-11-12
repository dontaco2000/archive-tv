import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/guide/guide_model.dart';
import 'package:archive_tv_player/ui/guide_overlay.dart';
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
  const b = Channel(number: 2, name: 'Bravo', genre: 'TV');
  const c = Channel(number: 3, name: 'Charlie', genre: 'Unknown');

  GuideModel model() => GuideModel(
        channels: const [a, b, c],
        now: now,
        tunableNumbers: {1, 2, 3},
        horizon: now.add(const Duration(days: 2)),
        slotsFor: (ch) => [
          slot('${ch.name} Early', DateTime(2026, 11, 11, 10), 30),
          slot('${ch.name} Late', DateTime(2026, 11, 11, 10, 30), 600),
          slot('Death Note S1E5', DateTime(2026, 11, 12, 9), 30),
        ],
      );

  String selectedTitle(WidgetTester t) {
    final cell = find.byKey(GuideOverlay.selectedKey);
    expect(cell, findsOneWidget);
    return t.widget<Text>(find.descendant(of: cell, matching: find.byType(Text))).data!;
  }

  Future<({List<Channel> tuned, List<Channel> highlighted, List<int> closed})> pump(WidgetTester t) async {
    final tuned = <Channel>[], highlighted = <Channel>[], closed = <int>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GuideOverlay(
          model: model(),
          onTune: tuned.add,
          onHighlight: highlighted.add,
          onClose: () => closed.add(1),
        ),
      ),
    ));
    await t.pump();
    return (tuned: tuned, highlighted: highlighted, closed: closed);
  }

  testWidgets('shows channel names and highlights the selected cell', (t) async {
    await pump(t);
    for (final n in ['Alpha', 'Bravo', 'Charlie']) {
      expect(find.text(n), findsWidgets);
    }
    expect(selectedTitle(t), 'Alpha Early');
    // first page: three hours in 15-minute columns, 10:15 .. 1:00
    for (final col in ['10:30', '11:45', '1:00']) {
      expect(find.text(col), findsOneWidget);
    }
    expect(find.text('1:15'), findsNothing);
  });

  testWidgets('Down and Right move the highlight', (t) async {
    final r = await pump(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(selectedTitle(t), 'Bravo Early');
    expect(r.highlighted, [b]);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    expect(selectedTitle(t), 'Bravo Late');
  });

  testWidgets('Right walks to later programs (next day too), Left comes back', (t) async {
    final r = await pump(t);
    for (var i = 0; i < 3; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    }
    await t.pump();
    expect(selectedTitle(t), 'Death Note S1E5');
    expect(find.text('Death Note S1E5  THU 9:00-9:30'), findsOneWidget); // header
    expect(find.text(' CH THU '), findsOneWidget);
    expect(find.text('9:15'), findsOneWidget); // 15-minute columns
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight); // last program: stays
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await t.pump();
    expect(selectedTitle(t), 'Alpha Late');
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(r.tuned, [a]); // OK still tunes the channel live
  });

  testWidgets('Enter tunes the selected channel, Esc closes', (t) async {
    final r = await pump(t);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(r.tuned, [b]);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(r.closed, [1]);
  });
}
