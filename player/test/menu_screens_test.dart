// Layout proof without a real window: renders the menu at the smallest window and TV sizes
// and saves PNGs. Runs (and passes) always; writes files only when MENU_SHOTS names a folder:
//   $env:MENU_SHOTS='D:\...\_build\screens'; flutter test test/menu_screens_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/menu_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final out = Platform.environment['MENU_SHOTS'];

  setUpAll(() async {
    // Real Consolas when this PC has it, so the PNGs show text instead of test boxes.
    for (final f in [r'C:\Windows\Fonts\consola.ttf', r'C:\Windows\Fonts\consolab.ttf']) {
      if (File(f).existsSync()) {
        final loader = FontLoader('Consolas')..addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
        await loader.load();
      }
    }
  });

  for (final (name, size) in [('small-640x480', const Size(640, 480)), ('tv-960x540', const Size(960, 540)), ('1080p', const Size(1920, 1080))]) {
    testWidgets('menu screenshot $name', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final boundary = GlobalKey();
      await t.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Material(
            child: RepaintBoundary(
              key: boundary,
              child: Container(
                decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF203040), Color(0xFF402818)])),
                child: MenuOverlay(
                  settings: Settings(),
                  current: const Channel(number: 4, name: 'Funnies'),
                  onChanged: (_) {},
                  onBlockCurrent: () {},
                  onRefresh: () {},
                  onClose: () {},
                  onOpenRemote: () {},
                  onWrongChannel: () {},
                  onSleep: () {},
                  onParental: () {},
                  onOpenSettingsFile: () {},
                  onOpenLogFolder: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await t.runAsync(() => precacheImage(const AssetImage(MenuOverlay.banner), t.element(find.byType(MenuOverlay))));
      await t.pump();

      Future<void> shot(String suffix) async {
        await t.pump();
        await t.pump();
        if (out == null) return;
        await t.runAsync(() async {
          final ro = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await ro.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          File('$out${Platform.pathSeparator}menu-$name-$suffix.png').writeAsBytesSync(png!.buffer.asUint8List());
        });
      }

      await shot('top');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.sendKeyEvent(LogicalKeyboardKey.enter); // Picture & Sound
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp); // wraps to the last row, scrolled into view
      await shot('picture-sound');
      expect(t.takeException(), isNull);
    });
  }
}
