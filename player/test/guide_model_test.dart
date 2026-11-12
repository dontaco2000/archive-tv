import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/guide/guide_model.dart';
import 'package:flutter_test/flutter_test.dart';

Slot slot(String title, DateTime start, int minutes) => Slot(
      Entry(id: title, itemId: title, file: '$title.mp4', title: title, durationSeconds: minutes * 60.0, url: 'u'),
      start,
      start.add(Duration(minutes: minutes)),
    );

DateTime at(int h, [int m = 0]) => DateTime(2026, 11, 11, h, m);

void main() {
  final now = at(10, 20);
  final a = const Channel(number: 1, name: 'A');
  final b = const Channel(number: 2, name: 'B');
  final c = const Channel(number: 3, name: 'C');
  final w = const Channel(number: 4, name: 'W', type: 'weather');

  GuideModel model({Set<int>? tunable, DateTime? horizon}) => GuideModel(
        channels: [a, b, c, w],
        now: now,
        tunableNumbers: tunable ?? {1, 2},
        horizon: horizon,
        slotsFor: (ch) => [
          slot('${ch.name}1', at(9, 30), 60), // 9:30-10:30 straddles window start
          slot('${ch.name}2', at(10, 30), 90), // to 12:00
          slot('${ch.name}3', at(12), 120), // to 14:00
          slot('${ch.name}4', at(14), 600), // to 24:00
        ],
      );

  test('15-minute grid: the first page shows three hours from the quarter hour before now', () {
    final m = model();
    expect(m.windowStart, at(10, 15));
    expect(m.columns.length, 12);
    expect(m.columns.take(4), [at(10, 15), at(10, 30), at(10, 45), at(11)]);
    expect(m.columns.last, at(13));
    expect(m.visible, const Duration(hours: 3)); // window 10:15-13:15
    expect(GuideModel.floor(at(10, 59)), at(10, 45));
    expect(GuideModel.floor(at(11, 0)), at(11));
  });

  test('Right walks to later programs, Left back, never before the one airing now', () {
    final m = model();
    expect(m.selectedSlot!.entry.title, 'A1');
    m.moveProgram(1);
    expect(m.selectedSlot!.entry.title, 'A2');
    expect(m.selectedTime, at(10, 30));
    m.moveProgram(1);
    expect(m.selectedSlot!.entry.title, 'A3');
    m.moveProgram(-1);
    expect(m.selectedSlot!.entry.title, 'A2');
    m.moveProgram(-1);
    expect(m.selectedSlot!.entry.title, 'A1');
    expect(m.selectedTime, now); // A1 started before now: the cursor stops at now
    m.moveProgram(-1);
    expect(m.selectedTime, now);
    expect(m.windowStart, at(10, 15));
  });

  test('the window scrolls so the selected program starts in view, and back', () {
    final m = model();
    m.moveProgram(1); // A2 at 10:30, inside 10:15-13:15
    m.moveProgram(1); // A3 at 12:00, still inside
    expect(m.windowStart, at(10, 15));
    m.moveProgram(1); // A4 at 14:00, past the window
    expect(m.windowStart, at(14));
    expect(m.rowsInView(1).single.cells.single.label, 'A4');
    m.moveProgram(-1); // A3 at 12:00, before the window
    expect(m.windowStart, at(12));
    expect(m.rowsInView(1).single.cells.map((c) => c.label), ['A3', 'A4']);
    m.moveProgram(-1); // A2 at 10:30
    expect(m.windowStart, at(10, 30));
    m.moveProgram(-1);
    expect(m.windowStart, at(10, 15));
  });

  test('Right stops at the last program and at the horizon', () {
    final m = model();
    for (var i = 0; i < 10; i++) {
      m.moveProgram(1);
    }
    expect(m.selectedSlot!.entry.title, 'A4');
    final h = model(horizon: at(12)); // A3 starts at the horizon: unreachable
    h.moveProgram(1);
    h.moveProgram(1);
    expect(h.selectedSlot!.entry.title, 'A2');
  });

  test('Up/Down keep the time cursor and select what airs then', () {
    final m = model();
    m.moveProgram(1);
    m.moveProgram(1); // 12:00
    m.moveRow(1);
    expect(m.selectedChannel, b);
    expect(m.selectedSlot!.entry.title, 'B3');
    m.moveProgram(-1);
    expect(m.selectedSlot!.entry.title, 'B2');
    m.moveRow(-5);
    expect(m.selectedRow, 0);
    expect(m.selectedSlot!.entry.title, 'A2');
  });

  test('rows without programs step 15 minutes, clamped at now and the horizon', () {
    final m = model(horizon: at(11));
    m.moveRow(2); // C is off air
    expect(m.selectedSlot, isNull);
    m.moveProgram(-1);
    expect(m.selectedTime, now);
    m.moveProgram(1);
    expect(m.selectedTime, at(10, 35));
    for (var i = 0; i < 10; i++) {
      m.moveProgram(1);
    }
    expect(m.selectedTime, at(10, 50)); // 11:05 would pass the horizon
  });

  test('cell labels are cleaned file names', () {
    final m = GuideModel(
      channels: [a],
      now: now,
      tunableNumbers: {1},
      slotsFor: (_) => [slot('Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb', at(10), 600)],
    );
    expect(m.rowsInView(1).single.cells.single.label, 'Martha Speaks S01E39');
  });

  test('slots are clipped to the 15-minute-aligned window but keep their titles', () {
    final cells = model().rowsInView(4).first.cells;
    expect(cells.first.label, 'A1');
    expect(cells.first.startFraction, 0);
    expect(cells.map((c) => c.label), ['A1', 'A2', 'A3']);
    expect(cells.first.endFraction, closeTo(15 / 180, 1e-9)); // 10:15-10:30
    expect(cells[1].startFraction, closeTo(15 / 180, 1e-9));
    expect(cells[1].endFraction, closeTo(105 / 180, 1e-9)); // 12:00
    expect(cells[2].endFraction, 1); // A3 runs past 13:15
  });

  test('off-air and unavailable channels get one placeholder cell', () {
    final m = model();
    final rows = m.rowsInView(4);
    expect(rows[2].tunable, isFalse);
    expect(rows[2].cells.single.label, 'OFF AIR');
    expect(rows[2].cells.single.endFraction, 1);
    expect(rows[3].cells.single.label, 'NOT AVAILABLE');
    m.moveRow(2);
    expect(m.selectedSlot, isNull);
  });

  test('a building channel shows BUILDING..., not OFF AIR', () {
    final m = GuideModel(channels: [a, b, c, w], now: now, tunableNumbers: {1}, buildingNumbers: {2}, slotsFor: (_) => []);
    final rows = m.rowsInView(4);
    expect(rows[1].tunable, isFalse);
    expect(rows[1].cells.single.label, buildingLabel);
    expect(rows[2].cells.single.label, 'OFF AIR'); // failed stays OFF AIR
  });

  test('rowsInView keeps the selection visible', () {
    final m = model();
    expect(m.rowsInView(2).map((r) => r.channel), [a, b]);
    m.moveRow(3);
    expect(m.rowsInView(2).map((r) => r.channel), [c, w]);
    m.moveRow(-2);
    expect(m.rowsInView(2).map((r) => r.channel), [b, c]);
  });

  test('rows show guide blocks: Marathon and More Commercials; Right/Left step block to block', () {
    const toons = Channel(number: 5, name: 'Toons');
    const ads = Channel(number: 6, name: 'Ads', shortContent: 'Commercials');
    final m = GuideModel(
      channels: [toons, ads],
      now: now,
      tunableNumbers: {5, 6},
      horizon: at(23),
      slotsFor: (ch) => ch == ads
          ? [for (var i = 0; i < 80; i++) slot('Spot $i', at(10).add(Duration(minutes: 3 * i)), 3)] // 10:00-14:00
          : [
              for (var i = 0; i < 5; i++) slot('Thomas S01E0${i + 1}', at(10).add(Duration(minutes: 25 * i)), 25),
              slot('Movie', at(12, 5), 90),
              slot('Clip A', at(13, 35), 10),
              slot('Clip B', at(13, 45), 10),
            ],
    );
    expect(m.selectedSlot!.entry.title, 'Thomas Marathon'); // 10:00-12:05, airing now
    expect(m.rowsInView(2).first.cells.map((c) => c.label), ['Thomas Marathon', 'Movie']); // Shorts at 13:35 is past the 10:15-13:15 window
    m.moveProgram(1);
    expect(m.selectedSlot!.entry.title, 'Movie');
    m.moveProgram(1);
    expect([m.selectedSlot!.entry.title, m.selectedSlot!.start, m.selectedSlot!.end], ['Shorts', at(13, 35), at(13, 55)]);
    m.moveProgram(-1);
    m.moveProgram(-1);
    expect(m.selectedSlot!.entry.title, 'Thomas Marathon');
    expect(m.selectedTime, now);
    m.moveRow(1);
    expect([m.selectedSlot!.entry.title, m.selectedSlot!.start, m.selectedSlot!.end], ['More Commercials', at(10), at(12)]);
    m.moveProgram(1);
    expect(m.selectedSlot!.entry.title, 'More Commercials'); // 12:00-14:00
    expect(m.selectedSlot!.start, at(12));
    m.moveProgram(1); // last block: stays
    expect(m.selectedSlot!.start, at(12));
  });
}
