import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

Entry entry(String title, {String? item}) =>
    Entry(id: '$title/${item ?? title}', itemId: item ?? title, file: 'f.mp4', title: title, durationSeconds: 1, url: 'u');

DateTime at(int h, [int m = 0, int s = 0]) => DateTime(2026, 11, 11, h, m, s);

/// Back-to-back slots from [start], one per (title, seconds).
List<Slot> run(DateTime start, List<(String, int)> items) {
  final out = <Slot>[];
  var t = start;
  for (final (title, secs) in items) {
    final next = t.add(Duration(seconds: secs));
    out.add(Slot(entry(title), t, next));
    t = next;
  }
  return out;
}

List<(String, DateTime, DateTime)> view(List<Slot> blocks) => [for (final b in blocks) (b.entry.title, b.start, b.end)];

void main() {
  group('showTitle', () {
    String show(String t, {String? item}) => showTitle(entry(t, item: item));
    test('cuts at season/episode markers', () {
      expect(show('Camp Lazlo - S04E08 - Strange Trout from Outer Space (406a)'), 'Camp Lazlo');
      expect(show('Death Note S1E5'), 'Death Note');
      expect(show('Martha.Speaks.S01E39.1080p.WEB-DL.AAC2.0.H.264-NTb'), 'Martha Speaks');
      expect(show('DuckmanS02E06 The Germ Turns'), 'Duckman');
      expect(show('Eek! The Cat 3x03 - Shark Doggy Dog'), 'Eek! The Cat');
      expect(show('Boboboubo Boubobo - 70'), 'Boboboubo Boubobo');
      expect(show('Powerpuff Girls - 05,04 - Burglar Alarmed'), 'Powerpuff Girls');
      expect(show('clueless- season 02 - episode 20 "Friends"'), 'Clueless');
      expect(show('cops-s-28-e-22'), 'Cops');
    });
    test('titles without markers are kept', () {
      expect(show('Apollo 13'), 'Apollo 13');
      expect(show('Night of the Living Dead'), 'Night of the Living Dead');
    });
    test('a title that is only a marker falls back to the item id', () {
      expect(show('S5E04 Is There a Muppet in the House', item: 'muppet_babies'), 'Muppet Babies');
      expect(show('S04E16 - Thomas and Stepney', item: 'thomas-and-friends-s01-s17'), 'Thomas And Friends');
    });
    test('keys ignore case and & vs and; different show names stay different', () {
      expect(showKey(entry('Thomas & Friends - S08E25 - Too Hot')), showKey(entry('thomas and friends S01E01')));
      expect(showKey(entry('Thomas the Tank Engine S02E05')), isNot(showKey(entry('Thomas & Friends S02E05'))));
    });
  });

  group('same-show runs', () {
    test('2 hours or more is a Marathon, 1:59 is just the show', () {
      final two = run(at(10), [for (var i = 1; i <= 4; i++) ('Thomas S01E0$i', 30 * 60)]);
      expect(view(guideBlocks(two)), [('Thomas Marathon', at(10), at(12))]);
      final short = run(at(10), [for (var i = 1; i <= 4; i++) ('Thomas S01E0$i', 30 * 60 - 15)]);
      expect(view(guideBlocks(short)), [('Thomas', at(10), at(11, 59))]);
    });
    test('serial slot labels merge across slot boundaries; a single episode stays as is', () {
      final s = run(at(18), [('X-Men S1E1', 40 * 60), ('X-Men S1E2', 40 * 60), ('X-Men S1E3', 40 * 60), ('Movie', 90 * 60)]);
      expect(view(guideBlocks(s)), [('X-Men Marathon', at(18), at(20)), ('Movie', at(20), at(21, 30))]);
      final one = run(at(18), [('X-Men S1E1', 40 * 60), ('Movie', 90 * 60)]);
      expect(guideBlocks(one), one);
    });
    test('the block keeps the first item so tuning info is unchanged', () {
      final s = run(at(10), [('A S1E1', 3600), ('A S1E2', 3600)]);
      expect(guideBlocks(s).single.entry.id, s.first.entry.id);
    });
  });

  group('short items', () {
    test('runs of 2+ short items become Shorts; a lone short item stays', () {
      final s = run(at(10), [('Movie', 3600), ('Pingu 1', 600), ('Popeye', 400), ('Show', 1800), ('Lone', 600), ('Show2', 1800)]);
      expect(view(guideBlocks(s)), [
        ('Movie', at(10), at(11)),
        ('Shorts', at(11), at(11, 16, 40)),
        ('Show', at(11, 16, 40), at(11, 46, 40)),
        ('Lone', at(11, 46, 40), at(11, 56, 40)),
        ('Show2', at(11, 56, 40), at(12, 26, 40)),
      ]);
    });
    test('fillers under 5 minutes in total join the block before', () {
      final s = run(at(17), [('Movie', 3420), ('Bumper', 60), ('Clip', 100), ('Show', 1800)]);
      expect(view(guideBlocks(s)), [('Movie', at(17), at(17, 59, 40)), ('Show', at(17, 59, 40), at(18, 29, 40))]);
    });
    test('long short runs are cut into 2-hour blocks on even hours', () {
      final s = run(at(10, 40), [for (var i = 0; i < 26; i++) ('Clip $i', 600)]); // 10:40-15:00
      expect(view(guideBlocks(s)), [
        ('Shorts', at(10, 40), at(12)),
        ('More Shorts', at(12), at(14)),
        ('Shorts', at(14), at(15)),
      ]);
    });
  });

  group('shortContent channels', () {
    List<Slot> spots(DateTime from, DateTime to) {
      final out = <Slot>[];
      for (var t = from; t.isBefore(to); t = t.add(const Duration(minutes: 3))) {
        out.add(Slot(entry('Spot ${t.minute}'), t, t.add(const Duration(minutes: 3))));
      }
      return out;
    }

    test('full 2-hour blocks say More, shorter ones just the label', () {
      expect(view(guideBlocks(spots(at(10, 39), at(15)), shortContent: 'Commercials')), [
        ('Commercials', at(10, 39), at(12)),
        ('More Commercials', at(12), at(14)),
        ('Commercials', at(14), at(15)),
      ]);
    });
    test('slivers under 30 minutes join the next or previous block', () {
      expect(view(guideBlocks(spots(at(9, 51), at(14, 9)), shortContent: 'PSAs')), [
        ('More PSAs', at(9, 51), at(12)),
        ('More PSAs', at(12), at(14, 9)),
      ]);
    });
    test('blocks stop at midnight; long items and same-show runs are still one block', () {
      final s = [
        ...spots(at(23), at(23, 30)),
        Slot(entry('Compilation 1'), at(23, 30), at(23, 59)),
        Slot(entry('Compilation 2'), at(23, 59), DateTime(2026, 11, 12, 1)),
      ];
      expect(view(guideBlocks(s, shortContent: 'Commercials')), [
        ('Commercials', at(23), DateTime(2026, 11, 12)),
        ('Commercials', DateTime(2026, 11, 12), DateTime(2026, 11, 12, 1)),
      ]);
    });
  });
}
