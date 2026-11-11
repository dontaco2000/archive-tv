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
}
