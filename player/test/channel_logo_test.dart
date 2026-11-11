import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/ui/channel_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(String name) =>
    MaterialApp(home: Scaffold(body: ChannelLogo(channel: Channel(number: 1, name: name), height: 60)));

void main() {
  test('every channel in the bundled channels.json has a logo asset', () {
    final config = parseChannelConfig(File('assets/channels.json').readAsStringSync());
    expect(config.channels, hasLength(30));
    for (final c in config.channels) {
      expect(File(logoAsset(c.name)).existsSync(), isTrue, reason: '${c.number} ${c.name}');
    }
  });

  testWidgets('known logo builds an Image', (t) async {
    await t.pumpWidget(_wrap('Drive-In'));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('unknown name falls back to its name as text', (t) async {
    await t.pumpWidget(_wrap('Nope Channel'));
    await t.pumpAndSettle();
    expect(find.text('Nope Channel'), findsOneWidget);
  });
}
