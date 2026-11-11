import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

Entry entry(String id, int minutes) => Entry(
      id: '$id/f.mp4',
      itemId: id,
      file: 'f.mp4',
      title: id,
      durationSeconds: minutes * 60.0,
      url: 'https://archive.org/download/$id/f.mp4',
    );

final pool = [entry('a', 25), entry('b', 50), entry('c', 95), entry('d', 30)];
final day = DateTime(2026, 11, 11);

void main() {
  test('day schedule is deterministic and contiguous from midnight to midnight', () {
    final one = scheduleDay(pool, 'ch5', day);
    final two = scheduleDay(pool, 'ch5', day);
    expect(one.map((s) => s.entry.id), two.map((s) => s.entry.id));
    expect(one.first.start, day);
    expect(one.last.end, DateTime(2026, 11, 12));
    for (var i = 1; i < one.length; i++) {
      expect(one[i].start, one[i - 1].end);
    }
  });

  test('different days and different channels shuffle differently', () {
    String ids(List<Slot> s) => s.map((x) => x.entry.id).take(4).join(',');
    final base = ids(scheduleDay(pool, 'ch5', day));
    final others = {
      for (var d = 12; d < 22; d++) ids(scheduleDay(pool, 'ch5', DateTime(2026, 11, d))),
      for (var c = 6; c < 16; c++) ids(scheduleDay(pool, 'ch$c', day)),
    };
    expect(others.length, greaterThan(3)); // not all the same order
    expect(others.contains(base) && others.length == 1, isFalse);
  });

  test('pool shorter than a day repeats; last slot is cut at midnight', () {
    final short = [entry('x', 10)];
    final slots = scheduleDay(short, 'ch1', day);
    expect(slots, hasLength(144));
    final cut = scheduleDay([entry('y', 7 * 60)], 'ch1', day).last;
    expect(cut.end, DateTime(2026, 11, 12));
    expect(cut.end.difference(cut.start), lessThan(const Duration(hours: 7)));
  });

  test('empty pool gives no slots; off air below the minimum', () {
    expect(scheduleDay([], 'ch1', day), isEmpty);
    expect(isOffAir(pool, 2 * 3600), isFalse); // 200 min
    expect(isOffAir([entry('a', 60)], 2 * 3600), isTrue);
  });

  test('slotAt and offsetSeconds find what is playing and where to seek', () {
    final slots = scheduleDay(pool, 'ch5', day);
    final t = day.add(const Duration(hours: 3, minutes: 7, seconds: 30));
    final s = slotAt(slots, t)!;
    expect(!t.isBefore(s.start) && t.isBefore(s.end), isTrue);
    expect(offsetSeconds(s, t), closeTo(t.difference(s.start).inSeconds, 0.001));
    expect(slotAt(slots, DateTime(2026, 11, 12)), isNull);
  });

  test('guide covers exactly 12 hours and crosses midnight', () {
    final now = DateTime(2026, 11, 11, 20);
    final g = guide(now, (d) => scheduleDay(pool, 'ch5', d));
    expect(g.first.start.isBefore(now) || g.first.start == now, isTrue);
    expect(g.last.end.isAfter(DateTime(2026, 11, 12, 7, 59)), isTrue);
    expect(g.last.start.isBefore(DateTime(2026, 11, 12, 8)), isTrue);
    expect(g.any((s) => s.start.day == 12), isTrue);
  });
}
