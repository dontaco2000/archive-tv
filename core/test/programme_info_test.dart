import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

Entry entry(String title, {String item = 'some-item'}) =>
    Entry(id: '$item/f.mp4', itemId: item, file: 'f.mp4', title: title, durationSeconds: 1800, url: 'u');

void main() {
  group('cleanTitle', () {
    test('track numbers, dotted names, trailing ids, season tags', () {
      expect(cleanTitle("05. Blue's Clues - Blue's Birthday"), "Blue's Clues - Blue's Birthday");
      expect(cleanTitle('12 - The Pilot'), 'The Pilot');
      expect(cleanTitle('Noggin.Block.44 EC#73 EC#181 EC#197'), 'Noggin Block 44');
      expect(cleanTitle('Cops S10'), 'Cops Season 10');
      expect(cleanTitle('Cops S10E05'), 'Cops S10E05');
      expect(cleanTitle('Cops S1 E5'), 'Cops S1 E5');
      expect(cleanTitle('Mr.Wizard_512kb'), 'Mr Wizard');
      expect(cleanTitle('Show.Name.S01E02.480i.TVRip.AAC2.0'), 'Show Name S01E02');
      expect(cleanTitle('06. BluRay - An Idiot Abroad Season 1 Episode 3 - Jordan'), 'An Idiot Abroad Season 1 Episode 3 - Jordan');
    });

    test('real titles with numbers survive', () {
      expect(cleanTitle('101 Dalmatians'), '101 Dalmatians');
      expect(cleanTitle('2001: A Space Odyssey'), '2001: A Space Odyssey');
      expect(cleanTitle('12 Angry Men (1957)'), '12 Angry Men (1957)');
      expect(cleanTitle('Dr. Who and the Daleks (1965)'), 'Dr. Who and the Daleks (1965)');
      expect(cleanTitle('U.S.A. Today'), 'U.S.A. Today');
      expect(cleanTitle("Blue's Clues S04E86 Blue's Big Treasure Hunt"), "Blue's Clues S04E86 Blue's Big Treasure Hunt");
    });
  });

  group('titleIsInformative', () {
    test('dates, numbers and generic labels are not', () {
      for (final t in ['1987-03-12', '19870312', '20240727 20240727 0523', 'Episode 5', 'EP 1', '12', '0523', 'Season 10',
        'video', 'VTS 01 1', 'DVD VIDEO', 'UNTITLED', 'Disc 1', 'Tape 1036 Disc 1', 'S25E01', 'AV-153', 'x44az75',
        '030689f2423e6b68d344052806099f39', 'March 1987', 'Part 3']) {
        expect(titleIsInformative(cleanTitle(t)), isFalse, reason: t);
      }
    });
    test('names are', () {
      for (final t in ["Blue's Clues S04E86", 'Noggin Block 44', 'The Tonight Show', 'Cops Season 10', '1984', 'lostmovie']) {
        expect(titleIsInformative(cleanTitle(t)), t == '1984' ? isFalse : isTrue, reason: t);
      }
    });
  });

  test('dateIn', () {
    expect(dateIn('1987-03-12'), DateTime(1987, 3, 12));
    expect(dateIn('19870312'), DateTime(1987, 3, 12));
    expect(dateIn('20240727 20240727 0523'), DateTime(2024, 7, 27));
    expect(dateIn('1-17-87'), DateTime(1987, 1, 17));
    expect(dateIn('clip(12/4/1987)'), DateTime(1987, 12, 4));
    expect(dateIn('10 October 2005'), DateTime(2005, 10, 10));
    expect(dateIn('March 12, 1987'), DateTime(1987, 3, 12));
    expect(dateIn('19871345'), isNull);
    expect(dateIn('Episode 12'), isNull);
    expect(formatDate(DateTime(1987, 3, 12)), 'Mar 12, 1987');
  });

  group('programmeInfo', () {
    const carson = ItemInfo('carson-1987',
        title: 'The Tonight Show Starring Johnny Carson',
        creator: 'NBC',
        date: '1987-03-12',
        description: '<p>Johnny&#39;s guests: <b>Bob Hope</b> &amp; friends.</p>');

    test('date-only file titles take the item title and the date as sub-title', () {
      for (final t in ['1987-03-12', '19870312', '1987.03.12.mp4']) {
        final i = programmeInfo(entry(t, item: 'carson-1987'), carson);
        expect(i.title, 'The Tonight Show Starring Johnny Carson', reason: t);
        expect(i.subTitle, 'Mar 12, 1987', reason: t);
        expect(i.label, 'The Tonight Show Starring Johnny Carson: Mar 12, 1987');
        expect(i.description, "Johnny's guests: Bob Hope & friends.");
        expect(i.airDate, DateTime(1987, 3, 12));
      }
      expect(programmeInfo(entry('20240727_20240727_0523'), carson).subTitle, isNull); // a capture stamp, not an air date
      expect(programmeInfo(entry('20240727_20240727_0523')).label, 'Some Item: Jul 27, 2024'); // no item info: the item id
    });

    test('generic labels become the sub-title', () {
      expect(programmeInfo(entry('Episode 5'), carson).label, 'The Tonight Show Starring Johnny Carson: Episode 5');
      expect(programmeInfo(entry('Season 10'), carson).subTitle, 'Season 10');
      expect(programmeInfo(entry('S10'), carson).subTitle, 'Season 10');
      expect(programmeInfo(entry('12'), carson).subTitle, '#12');
      expect(programmeInfo(entry('VTS_01_2'), carson).subTitle, 'Part 2');
      expect(programmeInfo(entry('video'), carson).subTitle, 'Mar 12, 1987'); // the item date
    });

    test('slugs prefer the item title, minus its words', () {
      const lost = ItemInfo('lostmovie', title: 'The Lost Movie (1931)');
      expect(programmeInfo(entry('lostmovie', item: 'lostmovie'), lost).label, 'The Lost Movie (1931)');
      const planet = ItemInfo('blue-planet-ii', title: 'Blue Planet II');
      expect(programmeInfo(entry('blue planet ii 01 one ocean'), planet).label, 'Blue Planet II: 01 One Ocean');
      // no item info: the slug, capitalised
      expect(programmeInfo(entry('the_brain_that_wouldnt_die')).label, 'The Brain That Wouldnt Die');
    });

    test('Noggin blocks and episode files keep their own title, with the description', () {
      const noggin = ItemInfo('noggin', title: 'Noggin blocks', description: 'Recorded off air.');
      final n = programmeInfo(entry('Noggin.Block.44 EC#73 EC#181 EC#197'), noggin);
      expect(n.label, 'Noggin Block 44');
      expect(n.description, 'Recorded off air.');
      final b = programmeInfo(entry("05. Blue's Clues S04E86 Blue's Big Treasure Hunt"));
      expect(b.label, "Blue's Clues S04E86 Blue's Big Treasure Hunt");
      expect(b.subTitle, isNull);
    });

    test('normal titles are untouched', () {
      for (final t in ['Plan 9 from Outer Space', 'Dr. Who and the Daleks (1965)', 'Martha Speaks S01E39', 'Pi']) {
        final i = programmeInfo(entry(t), const ItemInfo('x', title: 'Something Else'));
        expect(i.label, t == 'Pi' ? 'Something Else: Pi' : t); // 2 letters: the item title leads
      }
      expect(programmeInfo(entry('Pi')).label, 'Pi'); // no item info: a 2-letter title stays
    });

    test('no item info: item id, else a readable date, else the cleaned title', () {
      expect(programmeInfo(entry('1983-01-21', item: 'ABC-World-News-Tonight-1983')).label, 'ABC World News Tonight 1983: Jan 21, 1983');
      expect(programmeInfo(entry('Episode 2', item: 'QuantumLeapSeason1')).label, 'Quantum Leap Season 1: Episode 2');
      expect(programmeInfo(entry('01-28-89', item: '06-10-89')).label, 'Jan 28, 1989');
      expect(programmeInfo(entry('Episode 12', item: 'x44az75')).label, 'Episode 12');
      expect(programmeInfo(entry('S25E01', item: 'cops-s-28-e-22-1080p-amazon-web-dl')).title, 'Cops S 28 E 22');
    });

    test('real data shapes (2026-11-12 warm-up)', () {
      const conan = ItemInfo('c', title: 'CONAN TBS 2010');
      expect(programmeInfo(entry('conan.2010.11.16.harrison.ford.720p.hdtv.x264-bff'), conan).label,
          'CONAN TBS 2010: Nov 16, 2010 - Harrison Ford');
      const clueless = ItemInfo('c', title: 'Clueless (1996-99) TV series');
      expect(programmeInfo(entry('clueless- season 02 - episode 18 a friend'), clueless).subTitle, 'Season 02 Episode 18 A Friend');
      const mash = ItemInfo('m', title: 'M*A*S*H Season 3', creator: 'Alan Alda');
      expect(programmeInfo(entry('5 - O.R.'), mash).label, 'M*A*S*H Season 3: O.R');
      const film = ItemInfo('f', title: '1776', creator: 'American Broadcasting Company');
      expect(programmeInfo(entry('1776 20170302reel1'), film).title, '1776');
      const ql = ItemInfo('q', title: 'Quantum Leap Season 1');
      expect(programmeInfo(entry('Episode 2'), ql).label, 'Quantum Leap Season 1: Episode 2');
    });

    test('time stamps, dates already in the title, hyphen slugs', () {
      const oakley = ItemInfo('o', title: "105 Rosie O'Donnell MON 1999 OCT 18");
      final r = programmeInfo(entry('20240218_033429'), oakley);
      expect(r.label, "105 Rosie O'Donnell MON 1999 OCT 18");
      expect(r.airDate, isNull);
      const snl = ItemInfo('s', title: 'Saturday Night Live - Richard Pryor - February 6, 1980');
      expect(programmeInfo(entry('dvd-6658-saturday-night-live-richard-pryor-1980-02-06'), snl).subTitle, isNull);
      expect(programmeInfo(entry('an-idiot-abroad-season-1-episode-1')).label, 'An Idiot Abroad Season 1 Episode 1');
    });

    test('item title that is itself a date falls back to the creator', () {
      const i = ItemInfo('x', title: '1987-03-12', creator: 'WTBS Atlanta');
      expect(programmeInfo(entry('19870312'), i).label, 'WTBS Atlanta: Mar 12, 1987');
    });

    test('long descriptions are cut at a word', () {
      final d = plainDescription('word ' * 200)!;
      expect(d.length, lessThanOrEqualTo(maxDescription));
      expect(d, endsWith('word...'));
      expect(plainDescription('  <br/> '), isNull);
    });
  });

  test('idBatches stay under 50 ids and the 2,048-char query limit', () {
    final ids = [for (var i = 0; i < 230; i++) 'item-${'x' * (i % 70)}-$i'];
    final batches = idBatches(ids);
    expect(batches.expand((b) => b), ids);
    for (final b in batches) {
      expect(b.length, lessThanOrEqualTo(50));
      expect(idQuery(b).length, lessThanOrEqualTo(2048));
    }
    expect(batches.length, greaterThan(230 ~/ 50));
    expect(idQuery(['a', 'b']), 'identifier:("a" OR "b")');
  });

  group('ItemInfoStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('item_info'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('fetches only items that need it, over a fake HTTP client, caches to disk, once', () async {
      final queries = <String>[];
      final client = ArchiveClient(
          retryDelay: Duration.zero,
          client: MockClient((req) async {
            final q = req.url.queryParameters['q']!;
            queries.add(q);
            expect(req.url.queryParametersAll['fl[]'], ['identifier', 'title', 'creator', 'date', 'description']);
            expect(q.length, lessThanOrEqualTo(2048));
            final ids = RegExp(r'"([^"]+)"').allMatches(q).map((m) => m[1]!).where((id) => id != 'gone');
            return http.Response(
                jsonEncode({
                  'response': {
                    'docs': [
                      for (final id in ids)
                        {'identifier': id, 'title': 'Show $id', 'date': '1987-03-12T00:00:00Z', 'description': ['<i>About</i>', '$id.']},
                    ]
                  }
                }),
                200);
          }));
      final file = File('${dir.path}/item_info.json');
      final store = ItemInfoStore(file, fetch: client.itemInfos);
      final entries = [
        for (var i = 0; i < 120; i++) entry('1987-03-12', item: 'carson-$i'),
        entry('Plan 9 from Outer Space', item: 'plan9'), // fine on its own: not fetched
        entry('Episode 1', item: 'gone'), // unknown to Archive
      ];
      var updates = 0;
      expect(await store.enrich(entries, onUpdate: () => updates++), 121);
      expect(queries.length, 3);
      expect(updates, 3);
      expect(store['plan9'], isNull);
      expect(store['carson-7']!.date, '1987-03-12');
      expect(store['carson-7']!.description, 'About carson-7.');
      expect(store['gone']!.title, isNull); // remembered as "nothing found"
      expect(store.info(entries[7]).label, 'Show carson-7: Mar 12, 1987');

      // a new store reads the file lazily and asks nothing again
      final again = ItemInfoStore(file, fetch: client.itemInfos);
      expect(again['carson-119']!.title, 'Show carson-119');
      expect(await again.enrich(entries), 0);
      expect(queries.length, 3);
      // --all also fetches items that look fine
      expect(await again.enrich(entries, all: true), 1);
      expect(again['plan9']!.title, 'Show plan9');
    });

    test('failed batches are skipped, titles fall back, and a later run retries', () async {
      var fail = true;
      final store = ItemInfoStore(File('${dir.path}/item_info.json'), fetch: (ids) async {
        if (fail) throw const SocketException('offline');
        return [for (final id in ids) ItemInfo(id, title: 'Real $id')];
      });
      final e = entry('19870312', item: 'abc-tonight');
      expect(await store.enrich([e]), 0);
      expect(store.info(e).label, 'Abc Tonight: Mar 12, 1987'); // the item id
      fail = false;
      expect(await store.enrich([e]), 1);
      expect(store.info(e).label, 'Real abc-tonight: Mar 12, 1987');
    });

    test('a corrupt cache file starts empty; no fetch means offline', () async {
      final f = File('${dir.path}/item_info.json')..writeAsStringSync('{not json');
      final store = ItemInfoStore(f);
      expect(store['x'], isNull);
      expect(await store.enrich([entry('1')]), 0);
    });
  });
}
