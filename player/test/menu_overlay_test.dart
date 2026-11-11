import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ch = Channel(number: 4, name: 'Funnies');

  Future<({Settings settings, List<Settings> changed, List<String> calls})> pump(WidgetTester t,
      {bool remote = false, String? lanInfo}) async {
    final settings = Settings();
    final changed = <Settings>[], calls = <String>[];
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MenuOverlay(
          settings: settings,
          current: ch,
          onChanged: changed.add,
          onBlockCurrent: () => calls.add('block'),
          onRefresh: () => calls.add('refresh'),
          onClose: () => calls.add('close'),
          onOpenRemote: remote ? () => calls.add('remote') : null,
          remoteLanInfo: lanInfo,
        ),
      ),
    ));
    await t.pump();
    return (settings: settings, changed: changed, calls: calls);
  }

  String selected(WidgetTester t) =>
      t.widget<Text>(find.descendant(of: find.byKey(MenuOverlay.selectedKey), matching: find.byType(Text))).data!;

  Future<void> key(WidgetTester t, LogicalKeyboardKey k, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      await t.sendKeyEvent(k);
    }
    await t.pump();
  }

  testWidgets('arrows move the highlight and wrap', (t) async {
    await pump(t);
    expect(selected(t), 'On Demand');
    await key(t, LogicalKeyboardKey.arrowDown, 2);
    expect(selected(t), startsWith('Flip favorites only'));
    await key(t, LogicalKeyboardKey.arrowUp, 3);
    expect(selected(t), 'Close');
    await key(t, LogicalKeyboardKey.arrowUp);
    expect(selected(t), 'Weather: Hattiesburg, Mississippi');
  });

  testWidgets('Enter on Mute reports muted, Left/Right adjust volume', (t) async {
    final r = await pump(t);
    await key(t, LogicalKeyboardKey.arrowDown, 4);
    expect(selected(t), 'Mute: OFF');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.changed.single.muted, isTrue);
    expect(selected(t), 'Mute: ON');
    await key(t, LogicalKeyboardKey.arrowUp);
    await key(t, LogicalKeyboardKey.arrowRight, 5); // 80 -> 100, clamped
    expect(r.settings.volume, 100);
    await key(t, LogicalKeyboardKey.arrowLeft);
    expect(r.settings.volume, 95);
  });

  testWidgets('Enter on Favorite toggles the current channel; Block calls onBlockCurrent; Esc closes', (t) async {
    final r = await pump(t);
    await key(t, LogicalKeyboardKey.arrowDown);
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.favorites, {4});
    await key(t, LogicalKeyboardKey.arrowDown, 6);
    expect(selected(t), 'Block this item');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.calls, ['block']);
    await key(t, LogicalKeyboardKey.escape);
    expect(r.calls, ['block', 'close']);
  });

  testWidgets('remote items: Open remote calls back, Wi-Fi toggles, LAN info shows; hidden without a remote', (t) async {
    await pump(t);
    expect(find.text('Open remote'), findsNothing);
    final r = await pump(t, remote: true, lanInfo: 'Phone: http://192.168.1.5:8765/remote  PIN 1234');
    await key(t, LogicalKeyboardKey.arrowUp, 4); // Close, LAN info, Wi-Fi, Open remote
    expect(selected(t), 'Open remote');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.calls, ['remote']);
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(selected(t), 'Remote on Wi-Fi: OFF');
    await key(t, LogicalKeyboardKey.enter);
    expect(r.settings.remoteLan, isTrue);
    expect(find.textContaining('PIN 1234'), findsOneWidget);
  });
}
