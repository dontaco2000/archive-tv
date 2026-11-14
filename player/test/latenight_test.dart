// Late night adult mode (queue 34 + 35): stand-by line, viewer-discretion warning, R badge / guide marker,
// the parental toggle and the engine filter when it is OFF. Clocks are injected; no real window.
// PNGs only when LATENIGHT_SHOTS names a folder:
//   $env:LATENIGHT_SHOTS='D:\...\_build\screens'; flutter test test/latenight_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/engine/tv_engine.dart';
import 'package:archive_tv_player/guide/guide_model.dart';
import 'package:archive_tv_player/parental/parental.dart';
import 'package:archive_tv_player/parental/parental_flow.dart';
import 'package:archive_tv_player/parental/parental_ui.dart';
import 'package:archive_tv_player/settings/settings_file.dart';
import 'package:archive_tv_player/settings/settings_store.dart';
import 'package:archive_tv_player/ui/channel_logo.dart';
import 'package:archive_tv_player/ui/tv_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'tv_engine_test.dart' show FakeApi;

const _config = '''
{"channels": [
  {"number": 11, "name": "Haunt", "sources": [{"query": "x"}]},
  {"number": 2, "name": "Funnies", "sources": [{"query": "x"}]}
]}''';

void main() {
  final out = Platform.environment['LATENIGHT_SHOTS'];
  late Directory dir;
  late TvEngine engine;
  late Channel haunt, funnies;
  final films = {for (var i = 0; i < 6; i++) 'film$i': 95};

  setUpAll(() async {
    for (final f in [r'C:\Windows\Fonts\consola.ttf', r'C:\Windows\Fonts\consolab.ttf']) {
      if (File(f).existsSync()) {
        final loader = FontLoader('Consolas')..addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
        await loader.load();
      }
    }
  });

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('latenight');
    // Haunt's films are on the rated list (rated.json ids hold on every channel).
    engine = TvEngine.open(
        configText: _config,
        ratedText: '{"identifiers": {${films.keys.map((k) => '"$k": "R"').join(',')}}}',
        dataDir: dir,
        api: FakeApi({for (var i = 0; i < 30; i++) 'show$i': 30, ...films}));
    haunt = engine.channels.firstWhere((c) => c.number == 11);
    funnies = engine.channels.firstWhere((c) => c.number == 2);
    await engine.ensurePool(haunt);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  bool hasFilm(Iterable<Entry> l) => l.any((x) => x.itemId.startsWith('film'));
  final night = DateTime(2026, 11, 12, 23), day = DateTime(2026, 11, 12, 14);

  group('engine', () {
    test('adult mode OFF: rated entries never air, also from an already saved day; On Demand hides them', () {
      engine.planWeek(haunt, DateTime(2026, 11, 12)); // days saved with ON
      expect(hasFilm(engine.guideFor(haunt, DateTime(2026, 11, 12, 0, 0, 1), hours: 24).map((s) => s.entry)), isTrue);
      engine.adultMode = false;
      for (var d = 12; d < 19; d++) {
        expect(hasFilm(engine.guideFor(haunt, DateTime(2026, 11, d, 0, 0, 1), hours: 24).map((s) => s.entry)), isFalse);
      }
      final today = engine.guideFor(haunt, DateTime(2026, 11, 12, 0, 0, 1), hours: 24);
      expect(today.last.end.isBefore(DateTime(2026, 11, 13)), isFalse); // no dead air: the day is still full
      expect(hasFilm(engine.onDemandPoolOf(haunt)), isFalse);
      engine.adultMode = true;
      expect(hasFilm(engine.onDemandPoolOf(haunt)), isTrue);
    });

    test('lateNightOn: window x adult mode x channel has rated entries', () async {
      expect(engine.lateNightOn(haunt, night), isTrue);
      expect(engine.lateNightOn(haunt, DateTime(2026, 11, 12, 4, 59)), isTrue);
      expect(engine.lateNightOn(haunt, day), isFalse);
      expect(engine.lateNightOn(haunt, DateTime(2026, 11, 12, 5)), isFalse);
      engine.adultMode = false;
      expect(engine.lateNightOn(haunt, night), isFalse);

      await engine.ensurePool(funnies); // the films are rated by id on every channel: Funnies needs its own engine
      final cleanDir = Directory.systemTemp.createTempSync('latenight-clean');
      addTearDown(() => cleanDir.deleteSync(recursive: true));
      final clean = TvEngine.open(configText: _config, ratedText: '{"identifiers": {}}', dataDir: cleanDir, api: FakeApi({'show0': 30}));
      final c = clean.channels.first;
      await clean.ensurePool(c);
      expect(clean.lateNightOn(c, night), isFalse); // no rated entries
    });

    test('ratedNotice: full card at the start, banner mid-way, nothing when OFF or not rated', () {
      final slots = engine.guideFor(haunt, DateTime(2026, 11, 12, 22), hours: 7);
      final film = slots.firstWhere((s) => s.entry.itemId.startsWith('film'));
      final show = slots.firstWhere((s) => !s.entry.itemId.startsWith('film'));
      expect(ratedNotice(engine, Airing(haunt, film, 2, null)), RatedNotice.card);
      expect(ratedNotice(engine, Airing(haunt, film, 600, null)), RatedNotice.banner);
      expect(ratedNotice(engine, Airing(haunt, show, 0, null)), isNull);
      engine.adultMode = false;
      expect(ratedNotice(engine, Airing(haunt, film, 2, null)), isNull);
    });

    test('guide: rated cells carry the [R] marker, only while adult mode is ON', () {
      final at = DateTime(2026, 11, 12, 22);
      GuideModel model() => GuideModel(
            channels: [haunt],
            slotsFor: (c) => engine.guideFor(c, DateTime(2026, 11, 12), hours: 48),
            now: at,
            tunableNumbers: {haunt.number},
            isRated: engine.showsRated,
          );
      List<String> night() {
        final m = model(); // walk the night in 3-hour windows
        return [
          for (var h = 0; h < 3; h++)
            for (final c in (m..windowStart = at.add(Duration(hours: 3 * h))).rowsInView(1).single.cells) c.label
        ];
      }

      final all = night();
      expect(all.where((l) => l.startsWith(ratedMarker)), isNotEmpty);
      expect(all.where((l) => l.startsWith(ratedMarker)).every((l) => l.toLowerCase().contains('film')), isTrue);
      expect(all.where((l) => l.toLowerCase().contains('film')).every((l) => l.startsWith(ratedMarker)), isTrue);
      engine.adultMode = false;
      expect(night().where((l) => l.startsWith(ratedMarker)), isEmpty);
    });
  });

  group('parental toggle', () {
    test('row shown, change needs the PIN, persists, reset and Remove PIN restore ON', () {
      final p = Parental();
      final flashes = <String>[];
      PinRequest? asked;
      var saves = 0, changed = 0;
      final flow = ParentalFlow(p, save: () => saves++, flash: flashes.add, ask: (r) => asked = r)..afterAdultMode = () => changed++;
      List<(String, void Function()?)> rows() => parentalRows(p, const [], flow, () {}, () {});
      (String, void Function()?) row() => rows().firstWhere((r) => r.$1.startsWith('Late night adult mode'));

      expect(row().$1, 'Late night adult mode: ON');
      row().$2!();
      expect(flashes.last, 'Set a PIN first');
      expect(p.adultMode, isTrue);

      p.setPin('1234');
      for (final lockOn in [true, false]) {
        p.lockOn = lockOn;
        expect(rows().map((r) => r.$1), contains('Late night adult mode: ON'));
      }
      row().$2!(); // lock OFF still asks for the PIN
      expect(asked, isNotNull);
      expect(p.adultMode, isTrue);
      asked!.onPin('0000');
      expect(p.adultMode, isTrue);
      asked!.onPin('1234');
      expect(p.adultMode, isFalse);
      expect(changed, 1);
      expect(row().$1, 'Late night adult mode: OFF');
      expect(flashes.last, 'Late night adult mode OFF');

      final s = Settings()..parental = p;
      final again = Settings.fromJson(s.toJson());
      expect(again.parental.adultMode, isFalse);
      expect(Parental.fromJson(const {}).adultMode, isTrue); // default ON (older settings.json)

      expect(applySettingsText('reset_parental_controls=true', again, (_) {}), isTrue);
      expect(again.parental.adultMode, isTrue);

      flow.removePin();
      asked!.onPin('1234');
      expect(p.adultMode, isTrue);
      expect(changed, 2);
      expect(saves, greaterThan(0));
    });
  });

  group('widgets', () {
    Future<void> shot(WidgetTester t, GlobalKey key, String name) async {
      if (out == null) return;
      await t.runAsync(() async {
        final ro = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final png = await (await ro.toImage()).toByteData(format: ui.ImageByteFormat.png);
        File('$out${Platform.pathSeparator}latenight-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }

    Future<GlobalKey> frame(WidgetTester t, Widget child, {Color bg = Colors.black}) async {
      t.view.physicalSize = const Size(960, 720);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final key = GlobalKey();
      await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: RepaintBoundary(key: key, child: Container(color: bg, child: Stack(fit: StackFit.expand, children: [child]))))));
      return key;
    }

    const ch = Channel(number: 11, name: 'Haunt');

    testWidgets('stand-by card: the late-night line sits between the name and STAND BY; hidden otherwise', (t) async {
      final key = await frame(t, const StandByCard(channel: ch, lateNight: true));
      await t.runAsync(() => precacheImage(AssetImage(logoAsset('Haunt')), t.element(find.byType(StandByCard))));
      await t.pump();
      final line = find.text(lateNightLine);
      expect(line, findsOneWidget);
      final y = t.getCenter(line).dy;
      expect(t.getCenter(find.text('11  HAUNT')).dy, lessThan(y));
      expect(t.getCenter(find.textContaining('STAND BY')).dy, greaterThan(y));
      expect(t.getSize(find.byType(Image)).height, 280); // logo size unchanged
      final before = (t.widget<Text>(find.textContaining('STAND BY'))).data;
      await t.pump(const Duration(milliseconds: 460));
      expect(t.widget<Text>(find.textContaining('STAND BY')).data, isNot(before)); // dots still move
      await shot(t, key, 'standby-on');

      final key2 = await frame(t, const StandByCard(channel: ch));
      await t.runAsync(() => precacheImage(AssetImage(logoAsset('Haunt')), t.element(find.byType(StandByCard))));
      await t.pump();
      expect(find.text(lateNightLine), findsNothing);
      await shot(t, key2, 'standby-off');
    });

    testWidgets('warning card and mid-way banner; R badge in the info banner', (t) async {
      final key = await frame(t, const RatedWarning());
      expect(find.text('VIEWER DISCRETION ADVISED'), findsOneWidget);
      expect(find.text('MATURE CONTENT (R)'), findsOneWidget);
      expect(t.getSize(find.byType(RatedWarning)), const Size(960, 720)); // covers the frame
      await shot(t, key, 'warning-card');

      final s = Slot(Entry(id: 'f', itemId: 'f', file: 'f.mp4', title: 'Night of the Creeps', durationSeconds: 5400, url: 'u'),
          DateTime(2026, 11, 12, 22), DateTime(2026, 11, 12, 23, 30));
      final a = Airing(ch, s, 1200, null);
      final key2 = await frame(
          t,
          Stack(fit: StackFit.expand, children: [
            Container(color: const Color(0xFF304050)), // stands in for the video
            InfoBanner(channel: ch, airing: a, rated: true),
            const RatedWarning(banner: true),
          ]));
      await t.runAsync(() => precacheImage(AssetImage(logoAsset('Haunt')), t.element(find.byType(InfoBanner))));
      await t.pump();
      expect(find.textContaining('MATURE CONTENT (R)', findRichText: true), findsOneWidget);
      expect(t.getRect(find.byType(RatedWarning)).top, 0);
      expect(find.byKey(const ValueKey('rated-badge')), findsOneWidget);
      expect(t.takeException(), isNull);
      await shot(t, key2, 'warning-banner-and-badge');

      await frame(t, InfoBanner(channel: ch, airing: a));
      expect(find.byKey(const ValueKey('rated-badge')), findsNothing);
    });
  });
}
