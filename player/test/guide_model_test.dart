import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:archive_tv_player/guide/guide_model.dart';
import 'package:flutter_test/flutter_test.dart';

Slot slot(String title, DateTime start, int minutes) => Slot(
      Entry(id: title, itemId: title, file: '$title.mp4', title: title, durationSeconds: minutes * 60.0, url: 'u'),
      start,
      start.add(Duration(minutes: minutes)),
    );

void main() {
  final now = DateTime(2026, 11, 11, 10, 15);
  final h = DateTime(2026, 11, 11, 10); // window start
  final a = const Channel(number: 1, name: 'A');
  final b = const Channel(number: 2, name: 'B');
  final c = const Channel(number: 3, name: 'C');
  final w = const Channel(number: 4, name: 'W', type: 'weather');

  GuideModel model({Set<int>? tunable}) => GuideModel(
        channels: [a, b, c, w],
        now: now,
        tunableNumbers: tunable ?? {1, 2},
        slotsFor: (ch) => [
          slot('${ch.name}1', DateTime(2026, 11, 11, 9, 30), 60), // 9:30-10:30 straddles window start
          slot('${ch.name}2', DateTime(2026, 11, 11, 10, 30), 90), // to 12:00
          slot('${ch.name}3', DateTime(2026, 11, 11, 12), 600),
        ],
      );

  test('window starts at the half hour before now, six columns', () {
    final m = model();
    expect(m.windowStart, h);
    expect(m.columns.length, 6);
    expect(m.columns.last, DateTime(2026, 11, 11, 12, 30));
  });

  test('time clamps at now and at now + 12 h', () {
    final m = model();
    m.moveTime(const Duration(hours: -1));
    expect(m.selectedTime, now);
    for (var i = 0; i < 100; i++) {
      m.moveTime(const Duration(minutes: 30));
    }
    expect(m.selectedTime.isBefore(now.add(const Duration(hours: 12))), isTrue);
    expect(m.selectedTime.isAfter(now.add(const Duration(hours: 11))), isTrue);
  });

  test('moving right across the window edge shifts it by 30 minutes', () {
    final m = model();
    for (var i = 0; i < 5; i++) {
      m.moveTime(const Duration(minutes: 30)); // 12:45 still inside
    }
    expect(m.windowStart, h);
    m.moveTime(const Duration(minutes: 30)); // 13:15
    expect(m.windowStart, DateTime(2026, 11, 11, 10, 30));
    m.moveTime(const Duration(minutes: -30)); // back inside
    expect(m.windowStart, DateTime(2026, 11, 11, 10, 30));
  });

  test('cell labels are cleaned file names', () {
    final m = GuideModel(
      channels: [a],
      now: now,
      tunableNumbers: {1},
      slotsFor: (_) => [slot('Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb', h, 600)],
    );
    expect(m.rowsInView(1).single.cells.single.label, 'Martha Speaks S01E39');
  });

  test('slot straddling the window start is clipped but keeps its title', () {
    final cell = model().rowsInView(4).first.cells.first;
    expect(cell.label, 'A1');
    expect(cell.startFraction, 0);
    expect(cell.endFraction, closeTo(0.5 / 3, 1e-9));
  });

  test('selecting a row then moving time picks the covering slot', () {
    final m = model();
    m.moveRow(1);
    expect(m.selectedChannel, b);
    expect(m.selectedSlot!.entry.title, 'B1');
    m.moveTime(const Duration(minutes: 30)); // 10:45
    expect(m.selectedSlot!.entry.title, 'B2');
    m.moveRow(-5);
    expect(m.selectedRow, 0);
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

  test('rowsInView keeps the selection visible', () {
    final m = model();
    expect(m.rowsInView(2).map((r) => r.channel), [a, b]);
    m.moveRow(3);
    expect(m.rowsInView(2).map((r) => r.channel), [c, w]);
    m.moveRow(-2);
    expect(m.rowsInView(2).map((r) => r.channel), [b, c]);
  });
}
