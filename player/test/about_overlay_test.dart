import 'dart:io';

import 'package:archive_tv_player/ui/about_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<String>> pump(WidgetTester t, {required bool firstRun}) async {
    final closed = <String>[];
    t.view.physicalSize = const Size(1024, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(body: AboutOverlay(firstRun: firstRun, onClose: () => closed.add('close'))),
    ));
    await t.pump();
    return closed;
  }

  test('appVersion matches pubspec.yaml', () {
    final v = RegExp(r'^version:\s*([\d.]+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, v);
  });

  testWidgets('About shows version and notice; arrows do not close it, Esc does', (t) async {
    final closed = await pump(t, firstRun: false);
    expect(find.text('ABOUT ARCHIVE TV'), findsOneWidget);
    expect(find.text('Archive TV $appVersion'), findsOneWidget);
    for (final l in aboutLines) {
      expect(find.text(l), findsOneWidget);
    }
    expect(find.textContaining('not affiliated with or endorsed by the Internet Archive'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(closed, isEmpty);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closed, ['close']);
    expect(t.takeException(), isNull); // no overflow
  });

  testWidgets('logo sits above the title and fits small 4:3 windows', (t) async {
    for (final size in const [Size(1024, 768), Size(640, 480)]) {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: Scaffold(body: AboutOverlay(onClose: () {}))));
      await t.pump();
      final logo = find.image(const AssetImage('assets/branding/logo.png'));
      expect(logo, findsOneWidget);
      final h = t.getSize(logo).height;
      expect(h, inInclusiveRange(48, 128));
      expect(t.getRect(logo).bottom, lessThanOrEqualTo(t.getRect(find.text('ABOUT ARCHIVE TV')).top));
      expect(t.takeException(), isNull); // no overflow
    }
  });

  testWidgets('first-run notice: any key dismisses', (t) async {
    final closed = await pump(t, firstRun: true);
    expect(find.text('Click or press any key to continue'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(closed, ['close']);
  });

  testWidgets('a click or tap anywhere dismisses both the notice and About', (t) async {
    for (final firstRun in [true, false]) {
      final closed = await pump(t, firstRun: firstRun);
      expect(find.text(firstRun ? 'Click or press any key to continue' : 'Click or press Esc to close'), findsOneWidget);
      await t.tapAt(const Offset(512, 384)); // on the text panel
      await t.tapAt(const Offset(10, 10)); // outside the panel
      expect(closed, ['close', 'close']);
    }
  });
}
