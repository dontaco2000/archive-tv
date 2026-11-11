import 'dart:io';

import 'package:archive_tv_player/player/stall_watch.dart';
import 'package:archive_tv_player/settings/rotating_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StallWatch', () {
    final t0 = DateTime(2026, 11, 11, 20);

    test('no stall while the position keeps moving', () {
      final w = StallWatch(limit: const Duration(seconds: 8), now: t0);
      for (var s = 1; s <= 20; s++) {
        expect(w.check(Duration(seconds: s), t0.add(Duration(seconds: s))), isFalse);
      }
    });

    test('stalls once the position has not moved for the limit', () {
      final w = StallWatch(limit: const Duration(seconds: 8), now: t0);
      expect(w.check(const Duration(seconds: 5), t0.add(const Duration(seconds: 1))), isFalse);
      expect(w.check(const Duration(seconds: 5), t0.add(const Duration(seconds: 8))), isFalse);
      expect(w.check(const Duration(seconds: 5), t0.add(const Duration(seconds: 9, milliseconds: 1))), isTrue);
    });

    test('a paused player never counts as stalled', () {
      final w = StallWatch(limit: const Duration(seconds: 8), now: t0);
      expect(w.check(Duration.zero, t0.add(const Duration(seconds: 60)), paused: true), isFalse);
      // Resuming restarts the clock.
      expect(w.check(Duration.zero, t0.add(const Duration(seconds: 61))), isFalse);
      expect(w.check(Duration.zero, t0.add(const Duration(seconds: 70))), isTrue);
    });
  });

  group('RotatingLog', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('log'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('rolls over at the cap and keeps two old files', () {
      final f = File('${dir.path}/archive_tv.log');
      final log = RotatingLog(f, maxBytes: 100, keep: 2);
      for (var i = 0; i < 40; i++) {
        log.write('line ${i.toString().padLeft(3, '0')} xxxxxxxxxx'); // 26 bytes with newline
      }
      expect(f.lengthSync(), lessThanOrEqualTo(100));
      expect(File('${f.path}.1').existsSync(), isTrue);
      expect(File('${f.path}.2').existsSync(), isTrue);
      expect(File('${f.path}.3').existsSync(), isFalse);
      expect(f.readAsStringSync(), contains('line 039'));
    });

    test('an existing big log is rolled at startup', () {
      final f = File('${dir.path}/archive_tv.log')..writeAsStringSync('x' * 500);
      RotatingLog(f, maxBytes: 100).write('fresh');
      expect(File('${f.path}.1').lengthSync(), 500);
      expect(f.readAsStringSync(), 'fresh\n');
    });
  });
}
