import 'package:archive_tv_core/src/seeded_random.dart';
import 'package:test/test.dart';

void main() {
  test('SeededRandom matches the reference mulberry32 outputs for seed 1', () {
    final rng = SeededRandom(1);
    final got = List.generate(5, (_) => rng.nextUint32());
    expect(got, [2693262067, 11749833, 2265367787, 4213581821, 4159151403]);
  });

  test('stableHash matches reference FNV-1a values', () {
    expect(stableHash(''), 2166136261);
    expect(stableHash('a'), 3826002220);
    expect(stableHash('2|2026-11-11'), 2832414499);
  });

  test('seededShuffle is deterministic and a permutation', () {
    final items = List.generate(50, (i) => i);
    final a = seededShuffle(items, 42);
    final b = seededShuffle(items, 42);
    expect(a, b);
    expect(a.toSet(), items.toSet());
    expect(a, isNot(items));
  });

  test('different seeds give different orders', () {
    final items = List.generate(50, (i) => i);
    expect(seededShuffle(items, 1), isNot(seededShuffle(items, 2)));
  });

  test('seededShuffle does not modify its input', () {
    final items = [1, 2, 3, 4, 5];
    seededShuffle(items, 7);
    expect(items, [1, 2, 3, 4, 5]);
  });
}
