import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/ui/channel_logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(String name) =>
    MaterialApp(home: Scaffold(body: ChannelLogo(channel: Channel(number: 1, name: name), height: 60)));

void main() {
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
