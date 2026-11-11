import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

Entry e(String item, String file, [String? title]) => Entry(
      id: '$item/$file',
      itemId: item,
      file: file,
      title: title ?? file,
      durationSeconds: 1200,
      url: 'https://archive.org/download/$item/$file',
    );

void main() {
  group('searchTitles', () {
    final pool = [
      e('a', 'x.mp4', 'Spider-Man S01E03 Night of the Lizard'),
      e('b', 'y.mp4', 'The Real Ghostbusters 12'),
      e('c', 'z.mp4', 'spiderman_and_friends_01.mp4'),
    ];

    test('matches cleaned titles case-insensitively, sorted by title', () {
      expect(searchTitles(pool, 'spi').map((x) => x.itemId), ['a', 'c']);
      expect(searchTitles(pool, 'GHO').map((x) => x.itemId), ['b']);
    });

    test('an empty or blank query returns everything', () {
      expect(searchTitles(pool, '  '), hasLength(3));
    });
  });

  group('nextEpisode', () {
    test('next file of the same item in natural order', () {
      final pool = [e('show', 'ep10.mp4'), e('show', 'ep2.mp4'), e('show', 'ep1.mp4'), e('other', 'ep3.mp4')];
      expect(nextEpisode(pool, pool[2])!.file, 'ep2.mp4');
      expect(nextEpisode(pool, pool[1])!.file, 'ep10.mp4');
    });

    test('across items: same series name, next episode number', () {
      final pool = [
        e('i1', 'a.mp4', 'Dukes of Hazzard S01E01 One Armed Bandits'),
        e('i3', 'c.mp4', 'Dukes of Hazzard S01E03 Mary Kaye'),
        e('i2', 'b.mp4', 'Dukes of Hazzard S01E02 Daisy'),
        e('x', 'd.mp4', 'Hee Haw 1971'),
      ];
      expect(nextEpisode(pool, pool[0])!.itemId, 'i2');
      expect(nextEpisode(pool, pool[2])!.itemId, 'i3');
      expect(nextEpisode(pool, pool[1]), isNull); // last one
      expect(nextEpisode(pool, pool[3]), isNull); // no siblings
    });

    test('the last file of an item falls through to the next item of the series', () {
      final pool = [e('s1', 'Show 01.mp4', 'Show 01'), e('s1', 'Show 02.mp4', 'Show 02'), e('s2', 'Show 03.mp4', 'Show 03')];
      expect(nextEpisode(pool, pool[1])!.itemId, 's2');
    });

    test('titles that start with the episode number have no series name to match', () {
      final pool = [e('i1', 'a.mp4', 'S02E07 - Cabin Fever'), e('i2', 'b.mp4', 'S02E08 - Hide and Seek')];
      expect(nextEpisode(pool, pool[0]), isNull);
    });
  });

  test('naturalKey sorts numbers by value with a plain compare', () {
    final keys = ['Ep 10', 'ep 2', 'Ep 1'].map(naturalKey).toList()..sort();
    expect(keys, [naturalKey('Ep 1'), naturalKey('ep 2'), naturalKey('Ep 10')]);
  });

  test('seriesName cuts at the first episode or number token', () {
    expect(seriesName('Dukes of Hazzard S01E01 One Armed Bandits'), 'dukes of hazzard');
    expect(seriesName('Computer Chronicles - Episode 12'), 'computer chronicles');
    expect(seriesName('Show 1x05'), 'show');
    expect(seriesName('S02E07 - Cabin Fever'), '');
  });
}
