import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ch = Channel(number: 4, name: 'Funnies');

  /// Every optional callback given, so every item shows (Start fullscreen hides only on Android).
  Widget full(Settings settings, List<String> calls, {String? lanInfo = 'Phone: http://192.168.1.5:8765/remote  PIN 1234'}) =>
      MaterialApp(
        home: Scaffold(
          body: MenuOverlay(
            settings: settings,
            current: ch,
            onChanged: (_) => calls.add('changed'),
            onBlockCurrent: () => calls.add('block'),
            onRefresh: () => calls.add('refresh'),
            onClose: () => calls.add('close'),
            onOnDemand: () => calls.add('ondemand'),
            onWeatherLocation: () => calls.add('location'),
            onAbout: () => calls.add('about'),
            onCredits: () => calls.add('credits'),
            onCopyLastError: () => calls.add('copy'),
            onOpenLogFolder: () => calls.add('log'),
            onOpenRemote: () => calls.add('remote'),
            remoteLanInfo: lanInfo,
            onWrongChannel: () => calls.add('wrong'),
            onSleep: () => calls.add('sleep'),
            onParental: () => calls.add('parental'),
            onOpenSettingsFile: () => calls.add('file'),
          ),
        ),
      );

  Future<({Settings settings, List<String> calls})> pump(WidgetTester t, {Size size = const Size(960, 720)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = Settings(), calls = <String>[];
    await t.pumpWidget(full(settings, calls));
    await t.pump();
    return (settings: settings, calls: calls);
  }

  String selected(WidgetTester t) =>
      t.widget<Text>(find.descendant(of: find.byKey(MenuOverlay.selectedKey), matching: find.byType(Text))).data!;

  Future<void> key(WidgetTester t, LogicalKeyboardKey k, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await t.sendKeyEvent(k);
    }
    await t.pump();
    await t.pump(); // the post-frame scroll
  }

  /// From the top level, open the category whose row starts with [title].
  Future<void> open(WidgetTester t, String title) async {
    for (var i = 0; i < 12 && !selected(t).startsWith(title); i++) {
      await key(t, LogicalKeyboardKey.arrowDown);
    }
    expect(selected(t), startsWith(title));
    await key(t, LogicalKeyboardKey.enter);
  }

  /// Down from the current row until [label] is selected.
  Future<void> to(WidgetTester t, String label) async {
    for (var i = 0; i < 12 && !selected(t).startsWith(label); i++) {
      await key(t, LogicalKeyboardKey.arrowDown);
    }
    expect(selected(t), startsWith(label));
  }

  const topLevel = [
    'Channels & Guide  >',
    'Picture & Sound  >',
    'Weather  >',
    'Remote  >',
    'Sleep & Tools  >',
    'About & Credits  >',
    'Parental controls: OFF',
    'Close',
  ];

  test('menuClock is 12-hour with AM/PM', () {
    expect(menuClock(DateTime(2026, 11, 12, 15, 42)), '3:42 PM');
    expect(menuClock(DateTime(2026, 11, 12, 0, 5)), '12:05 AM');
    expect(menuClock(DateTime(2026, 11, 12, 12, 0)), '12:00 PM');
  });

  testWidgets('header: banner image and a live clock centered under it', (t) async {
    await pump(t);
    final banner = find.byWidgetPredicate((w) => w is Image && w.image is AssetImage && (w.image as AssetImage).assetName == MenuOverlay.banner);
    expect(banner, findsOneWidget);
    final clock = t.widget<Text>(find.byKey(MenuOverlay.clockKey));
    expect(clock.data, matches(RegExp(r'^\d{1,2}:\d\d [AP]M$')));
    expect(t.getCenter(find.byKey(MenuOverlay.clockKey)).dx, closeTo(t.getCenter(banner).dx, 1));
    expect(t.getTopLeft(find.byKey(MenuOverlay.clockKey)).dy, greaterThanOrEqualTo(t.getBottomLeft(banner).dy));
  });

  testWidgets('top level lists the categories; Enter opens one, Esc steps back, Esc at the top closes', (t) async {
    final r = await pump(t);
    final labels = t.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList();
    for (final l in topLevel) {
      expect(labels, contains(l));
    }
    await open(t, 'Picture & Sound');
    expect(find.text('PICTURE & SOUND'), findsOneWidget);
    expect(selected(t), startsWith('Volume')); // first item, under Back
    await key(t, LogicalKeyboardKey.arrowUp);
    expect(selected(t), '<  Back');
    await key(t, LogicalKeyboardKey.enter);
    expect(selected(t), 'Picture & Sound  >');
    await open(t, 'Picture & Sound');
    await key(t, LogicalKeyboardKey.escape);
    expect(selected(t), 'Picture & Sound  >');
    expect(r.calls, isEmpty);
    await key(t, LogicalKeyboardKey.escape);
    expect(r.calls, ['close']);
  });

  testWidgets('M closes from inside a category; back() reports whether it went up', (t) async {
    final r = await pump(t);
    final state = t.state<MenuOverlayState>(find.byType(MenuOverlay));
    expect(state.back(), isFalse);
    await open(t, 'Weather');
    expect(state.back(), isTrue);
    await t.pump();
    expect(selected(t), 'Weather  >');
    await open(t, 'Weather');
    await key(t, LogicalKeyboardKey.keyM);
    expect(r.calls, ['close']);
  });

  testWidgets('every former item is still reachable', (t) async {
    await pump(t);
    final seen = <String>{};
    for (final cat in topLevel.where((l) => l.endsWith('>'))) {
      await open(t, cat.replaceAll('  >', ''));
      await key(t, LogicalKeyboardKey.arrowUp); // Back
      final first = selected(t);
      do {
        seen.add(selected(t));
        await key(t, LogicalKeyboardKey.arrowDown);
      } while (selected(t) != first);
      await key(t, LogicalKeyboardKey.escape);
    }
    for (final label in [
      'On Demand', 'Favorite 4 Funnies: NO', 'Flip favorites only: OFF', 'Refresh channels', //
      'Volume ################.... 80', 'Mute: OFF', 'Volume leveling: NORMAL', 'Picture: AUTO', 'Captions: OFF',
      'Caption size ####... 4', 'Start fullscreen: OFF', 'Corner bug: OFF',
      'Weather view: WEATHERSTAR', 'Weather: Hattiesburg, Mississippi',
      'Remote window: OFF', 'Remote on Wi-Fi: OFF', 'Phone: http://192.168.1.5:8765/remote  PIN 1234',
      'Sleep timer: OFF', 'Wrong channel for this program', 'Block this item', 'Last error: none', 'Open log folder',
      'Open settings file', 'About', 'Credits',
    ]) {
      expect(seen, contains(label));
    }
    // + Parental controls and Close on the top level = all 27 former items.
  });

  testWidgets('items act as before: volume, mute, favorite, picture, block, callbacks', (t) async {
    final r = await pump(t);
    await open(t, 'Channels & Guide');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.calls, ['ondemand']);
    await to(t, 'Favorite');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.favorites, {4});
    await to(t, 'Refresh');
    await key(t, LogicalKeyboardKey.enter);
    await key(t, LogicalKeyboardKey.escape);

    await open(t, 'Picture & Sound');
    await key(t, LogicalKeyboardKey.arrowRight, 5); // 80 -> 100, clamped
    expect(r.settings.volume, 100);
    await key(t, LogicalKeyboardKey.arrowLeft);
    expect(r.settings.volume, 95);
    await to(t, 'Mute');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.muted, isTrue);
    await to(t, 'Volume leveling');
    await key(t, LogicalKeyboardKey.enter);
    expect(selected(t), 'Volume leveling: STRONG');
    await to(t, 'Picture');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.picture, 'fill');
    await key(t, LogicalKeyboardKey.arrowRight);
    expect(selected(t), 'Picture: OFF');
    await to(t, 'Captions');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.captionsOn, isTrue);
    await to(t, 'Caption size');
    await key(t, LogicalKeyboardKey.arrowRight, 5);
    expect(r.settings.captionSize, 7);
    await key(t, LogicalKeyboardKey.escape);

    await open(t, 'Sleep & Tools');
    await key(t, LogicalKeyboardKey.enter); // sleep
    await to(t, 'Wrong channel');
    await key(t, LogicalKeyboardKey.enter);
    await to(t, 'Block');
    await key(t, LogicalKeyboardKey.enter);
    await to(t, 'Last error');
    await key(t, LogicalKeyboardKey.enter);
    await key(t, LogicalKeyboardKey.escape);

    await open(t, 'Remote');
    await key(t, LogicalKeyboardKey.enter);
    await to(t, 'Remote on Wi-Fi');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.remoteLan, isTrue);
    await key(t, LogicalKeyboardKey.escape);

    await open(t, 'About & Credits');
    await key(t, LogicalKeyboardKey.enter);
    await to(t, 'Credits');
    await key(t, LogicalKeyboardKey.enter);
    await key(t, LogicalKeyboardKey.escape);

    await to(t, 'Parental controls');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.calls.where((c) => c != 'changed'),
        ['ondemand', 'refresh', 'sleep', 'wrong', 'block', 'copy', 'remote', 'about', 'credits', 'parental']);
  });

  testWidgets('categories without visible items are hidden (no remote, no tools callbacks)', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MenuOverlay(
          settings: Settings(),
          current: ch,
          onChanged: (_) {},
          onBlockCurrent: () {},
          onRefresh: () {},
          onClose: () {},
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Remote  >'), findsNothing);
    expect(find.textContaining('Parental'), findsNothing);
    expect(find.text('Sleep & Tools  >'), findsOneWidget); // Block this item and Last error always show
  });

  for (final (name, size) in [('smallest window', const Size(640, 480)), ('TV', const Size(960, 540)), ('1080p', const Size(1920, 1080))]) {
    testWidgets('$name: rows keep a readable size, the selected row stays visible while scrolling', (t) async {
      await pump(t, size: size);
      await open(t, 'Picture & Sound');
      final viewport = t.getRect(find.byType(SingleChildScrollView));
      final scroll = t.state<ScrollableState>(find.byType(Scrollable)).position;
      var maxOffset = 0.0;
      for (var i = 0; i < 11; i++) {
        if (scroll.pixels > maxOffset) maxOffset = scroll.pixels;
        final row = t.getRect(find.byKey(MenuOverlay.selectedKey));
        expect(row.top, greaterThanOrEqualTo(viewport.top - 0.5), reason: selected(t));
        expect(row.bottom, lessThanOrEqualTo(viewport.bottom + 0.5), reason: selected(t));
        expect(row.height, greaterThanOrEqualTo(24));
        final text = t.widget<Text>(find.descendant(of: find.byKey(MenuOverlay.selectedKey), matching: find.byType(Text)));
        expect(text.style!.fontSize, greaterThanOrEqualTo(13));
        await key(t, LogicalKeyboardKey.arrowUp); // wraps to the bottom first
      }
      expect(t.takeException(), isNull); // no overflow
      if (size.height == 480) expect(maxOffset, greaterThan(0)); // Picture & Sound is taller than the smallest window
    });
  }
}
