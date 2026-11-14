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

  group('groupShows', () {
    Map<String, List<String>> shows(ShowList l) => {for (final s in l.shows) s.name: [for (final x in s.entries) x.title]};

    test('series names group episodes across items, in natural order; films are singles', () {
      final l = groupShows([
        e('garg2', 'b.mp4', 'Gargoyles S01E10 Deadly Force'),
        e('garg1', 'a.mp4', 'Gargoyles S01E03 Awakening Part 3'),
        e('garg1', 'c.mp4', 'Gargoyles.S01E02.Awakening.Part.2.480p.WEB-DL.x264'),
        e('dw', '1.mp4', 'Doctor Who - 1974 - 03 Robot'),
        e('dw', '2.mp4', 'Doctor Who - 1974 - 01 Planet of the Spiders'),
        e('soap', '1.mp4', 'Soap 2x05'),
        e('soap2', '1.mp4', 'SOAP 1x01'),
        e('nld', 'nld.mp4', 'Night of the Living Dead (1968)'),
        e('ad', 'x.mp4', '2001: A Space Odyssey'),
      ]);
      expect(shows(l), {
        'Doctor Who': ['Doctor Who - 1974 - 01 Planet of the Spiders', 'Doctor Who - 1974 - 03 Robot'],
        'Gargoyles': ['Gargoyles.S01E02.Awakening.Part.2.480p.WEB-DL.x264', 'Gargoyles S01E03 Awakening Part 3', 'Gargoyles S01E10 Deadly Force'],
        'Soap': ['SOAP 1x01', 'Soap 2x05'],
      });
      expect(l.singles.map((x) => x.itemId), ['ad', 'nld']);
    });

    test('titles without a series part use the item name; date-named files sort by date', () {
      final l = groupShows([
        e('tonight-show-1987', '1987-03-12.mp4', '1987-03-12'),
        e('tonight-show-1987', '1987-01-02.mp4', '1987-01-02'),
        e('das1_20241125', 'a.mp4', 'S01E03 - Flushed'),
        e('das1_20241125', 'b.mp4', 'S01E01 - Pilot'),
        e('QLSeason5', 'a.mp4', 'Episode 22'),
        e('QLSeason4', 'a.mp4', 'Episode 2'),
      ], itemInfo: (id) => switch (id) {
            'das1_20241125' => const ItemInfo('das1_20241125', title: 'Dark Angel Season 1'),
            'QLSeason5' => const ItemInfo('QLSeason5', title: 'Quantum Leap Season 5'),
            'QLSeason4' => const ItemInfo('QLSeason4', title: 'Quantum Leap - Season 4'),
            _ => null,
          });
      expect(shows(l), {
        'Dark Angel': ['S01E01 - Pilot', 'S01E03 - Flushed'],
        'Quantum Leap': ['Episode 2', 'Episode 22'],
        'Tonight Show': ['1987-01-02', '1987-03-12'],
      });
      expect(l.singles, isEmpty);
    });

    test('numbered movie parts make one show; " - " prefixes and items regroup leftovers', () {
      final l = groupShows([
        e('m', '1.mp4', 'The Lost World Part 1'),
        e('m', '2.mp4', 'The Lost World Part 2'),
        e('tex', '1.mp4', 'Tex Avery - Bad Luck Blackie'),
        e('tex', '2.mp4', 'Tex Avery - Red Hot Riding Hood'),
        e('recessfullseries', '1.mp4', 'All Growed Down'),
        e('recessfullseries', '2.mp4', 'The Break In'),
        e('one', 'x.mp4', 'Curse of Bigfoot'),
      ]);
      expect(shows(l).keys, ['Recessfullseries', 'Tex Avery', 'The Lost World']);
      expect(l.singles.single.title, 'Curse of Bigfoot');
    });

    test('duplicates: one entry id once, a film uploaded twice is one single', () {
      final a = e('dotd', 'a.mp4', 'Dawn of the Dead');
      final l = groupShows([a, a, e('dotd2', 'b.mp4', 'Dawn Of The Dead'), e('x', 'y.mp4', 'Rhoda - S01E01'), e('x', 'z.mp4', 'Rhoda - S01E02')]);
      expect(shows(l), {'Rhoda': ['Rhoda - S01E01', 'Rhoda - S01E02']});
      expect(l.singles, [a]);
    });

    test('films with a year: one per year, never a show', () {
      final l = groupShows([
        e('a', '1.mp4', 'Dawn Of The Dead 1978'),
        e('b', '1.mp4', 'Dawn of the Dead (1978)'),
        e('c', '1.mp4', 'A Christmas Carol (1910)'),
        e('d', '1.mp4', 'A Christmas Carol (1969)'),
      ]);
      expect(l.shows, isEmpty);
      expect(l.singles.map((x) => x.itemId), ['c', 'd', 'a']);
    });

    test('spelled-out dates, brackets and capitals: one show, mixed-case name', () {
      final l = groupShows([
        e('a', '1.mp4', 'All My Children (December 8, 1986)'),
        e('b', '1.mp4', 'ALL MY CHILDREN 1987-01-02'),
        e('c', '1.mp4', 'All My Children May 12 1992'),
        e('d', '1.mp4', 'Baywatch(The Complete Series) 001-Panic At Malibu Pier'),
        e('d', '2.mp4', "''Baywatch'' 002"),
      ]);
      expect(shows(l).keys, ['All My Children', 'Baywatch']);
      expect(shows(l)['All My Children'], ['All My Children (December 8, 1986)', 'ALL MY CHILDREN 1987-01-02', 'All My Children May 12 1992']);
    });
  });

  test('episodeLabel drops the show name', () {
    expect(episodeLabel('Gargoyles', 'Gargoyles S01E03 Awakening'), 'S01E03 Awakening');
    expect(episodeLabel('Rhoda', 'Rhoda - S04E14'), 'S04E14');
    expect(episodeLabel('Tonight Show', 'Tonight Show'), 'Tonight Show');
    expect(episodeLabel('QL', 'Episode 22'), 'Episode 22');
  });

  test('rankMatches: word starts first, then anywhere; blank matches nothing', () {
    final names = ['Batman', 'The Bat Cave', 'Acrobats', 'Soap'];
    expect(rankMatches(names, (s) => s, 'bat'), ['Batman', 'The Bat Cave', 'Acrobats']);
    expect(rankMatches(names, (s) => s, ' '), isEmpty);
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
