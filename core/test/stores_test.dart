import 'dart:convert';
import 'dart:io';

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
  test('snapshots: saved once, survive a changed pool, ensureWeek, prune', () {
    final dir = Directory.systemTemp.createTempSync('snap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SnapshotStore(dir);

    final first = store.day(5, day, pool);
    final again = store.day(5, day, [entry('zzz', 40)]); // pool changed since
    expect(again.map((s) => s.entry.id), first.map((s) => s.entry.id));
    expect(again.first.start, first.first.start);

    store.ensureWeek(5, day, pool);
    expect(dir.listSync().where((f) => f.path.contains('day-5-')), hasLength(7));

    store.prune(DateTime(2026, 11, 13));
    expect(dir.listSync().where((f) => f.path.contains('day-5-')), hasLength(5));
  });

  test('a saved day from another channel (no item in the pool) is made again; an overlapping one stays', () {
    final dir = Directory.systemTemp.createTempSync('snap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final first = SnapshotStore(dir).day(5, day, pool).map((s) => s.entry.id).toList();
    // a later pool sharing half the items: today's saved day stays as it was
    final mixed = [entry('a', 25), entry('b', 50), entry('x', 60), entry('y', 60)];
    expect(SnapshotStore(dir).day(5, day, mixed).map((s) => s.entry.id), first);
    // a pool with none of the saved items (the number now belongs to another channel): remade from the pool
    final other = [entry('p', 30), entry('q', 45)];
    final remade = SnapshotStore(dir).day(5, day, other);
    expect(remade.map((s) => s.entry.itemId).toSet(), {'p', 'q'});
    expect(SnapshotStore(dir).day(5, day, other).map((s) => s.entry.id), remade.map((s) => s.entry.id)); // saved
  });

  test('dropAfter forgets the channel\'s later days only (today and other channels stay)', () {
    final dir = Directory.systemTemp.createTempSync('snap');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SnapshotStore(dir)
      ..ensureWeek(5, day, pool, days: 3)
      ..ensureWeek(6, day, pool, days: 3);
    store.dropAfter(5, day);
    final names = {for (final f in dir.listSync()) f.uri.pathSegments.last};
    expect(names, {'day-5-2026-11-11.json', 'day-6-2026-11-11.json', 'day-6-2026-11-12.json', 'day-6-2026-11-13.json'});
    expect(store.day(5, day.add(const Duration(days: 1)), [entry('new', 60)]).every((s) => s.entry.itemId == 'new'), isTrue);
  });

  test('a day is read from disk once, then served from memory', () {
    final dir = Directory.systemTemp.createTempSync('snapmem');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SnapshotStore(dir);
    final first = store.day(5, day, pool);
    for (final f in dir.listSync()) {
      f.deleteSync();
    }
    final again = store.day(5, day, [entry('zzz', 40)]);
    expect(again.map((s) => s.entry.id), first.map((s) => s.entry.id));
  });

  test('a day read from disk shares the pool\'s Entry objects (no second copy per day)', () {
    final dir = Directory.systemTemp.createTempSync('snapshare');
    addTearDown(() => dir.deleteSync(recursive: true));
    SnapshotStore(dir).day(5, day, pool);
    final read = SnapshotStore(dir).day(5, day, pool); // a fresh store reads the file
    expect(read.every((s) => pool.any((e) => identical(e, s.entry))), isTrue);
  });

  test('pool store round-trips and blocklist filters by entry or item', () {
    final dir = Directory.systemTemp.createTempSync('pool');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = PoolStore(dir);
    expect(store.load(5), isNull);
    store.save(5, pool);
    expect(store.load(5)!.map((e) => e.id), pool.map((e) => e.id));
    expect(store.age(5)!.inMinutes, 0);

    final block = Blocklist.load(dir)..add('a/f.mp4')..add('c');
    expect(block.apply(pool).map((e) => e.itemId), ['b', 'd']);
    expect(Blocklist.load(dir).ids, {'a/f.mp4', 'c'}); // persisted
  });

  test('session blocklist hides ids without touching disk', () {
    final block = Blocklist.session()..add('c');
    expect(block.apply(pool).map((e) => e.itemId), ['a', 'b', 'd']);
    final dir = Directory.systemTemp.createTempSync('sess');
    addTearDown(() => dir.deleteSync(recursive: true));
    final persistent = Blocklist.load(dir)..add('a');
    final both = persistent.union(block);
    expect(both.ids, {'a', 'c'});
    expect(Blocklist.load(dir).ids, {'a'}); // union and session add wrote nothing
    expect(dir.listSync(), hasLength(1)); // only blocked.json
  });

  test('wrong-channel list blocks per channel, persists, and a bad file reads as empty', () {
    final dir = Directory.systemTemp.createTempSync('wrong');
    addTearDown(() => dir.deleteSync(recursive: true));
    final wrong = ChannelBlocklist.load(dir)..add(5, 'c')..add(5, 'a')..add(7, 'b');
    expect(wrong.forChannel(5).apply(pool).map((e) => e.itemId), ['b', 'd']);
    expect(wrong.forChannel(7).apply(pool).map((e) => e.itemId), ['a', 'c', 'd']);
    expect(wrong.forChannel(9).apply(pool), hasLength(4)); // other channels untouched
    expect(ChannelBlocklist.load(dir).ids, {5: {'a', 'c'}, 7: {'b'}}); // persisted
    expect(jsonDecode(File('${dir.path}/wrong_items.json').readAsStringSync()), {'5': ['a', 'c'], '7': ['b']});

    for (final bad in ['not json', '["a"]', '{"x": ["a"], "5": "a", "6": [1, "b"]}']) {
      File('${dir.path}/wrong_items.json').writeAsStringSync(bad);
      final w = ChannelBlocklist.load(dir);
      expect(w.forChannel(5).apply(pool), hasLength(4), reason: bad);
      expect(w.ids.keys, bad.startsWith('{') ? [6] : isEmpty, reason: bad); // only well-formed rows survive
    }
  });

  test('blocking an item removes it from a saved day and later slots still tile', () {
    final dir = Directory.systemTemp.createTempSync('snapblock');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SnapshotStore(dir);
    final first = store.day(5, day, pool);
    final victim = first[1].entry;
    final block = Blocklist.load(dir)..add(victim.id);

    final after = store.day(5, day, [entry('zzz', 40)], blocklist: block);
    expect(after.any((s) => s.entry.id == victim.id), isFalse);
    expect(after.first.start, day);
    expect(after.last.end, DateTime(2026, 11, 12));
    for (var i = 1; i < after.length; i++) {
      expect(after[i].start, after[i - 1].end);
    }
  });

  test('corrupt files behave as missing and are rebuilt', () {
    final dir = Directory.systemTemp.createTempSync('corrupt');
    addTearDown(() => dir.deleteSync(recursive: true));
    final sep = Platform.pathSeparator;
    File('${dir.path}${sep}pool-5.json').writeAsStringSync('{"entries": [');
    expect(PoolStore(dir).load(5), isNull);
    File('${dir.path}${sep}blocked.json').writeAsStringSync('');
    expect(Blocklist.load(dir).ids, isEmpty);
    File('${dir.path}${sep}blocked.json').writeAsStringSync('[not json');
    expect(Blocklist.load(dir).ids, isEmpty);

    File('${dir.path}${sep}day-5-2026-11-11.json').writeAsStringSync('garbage');
    final slots = SnapshotStore(dir).day(5, day, pool);
    expect(slots, isNotEmpty);
    expect(jsonDecode(File('${dir.path}${sep}day-5-2026-11-11.json').readAsStringSync()), isList);
  });
}
