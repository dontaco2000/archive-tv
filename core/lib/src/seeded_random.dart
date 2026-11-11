import 'dart:convert';

/// Small deterministic PRNG (mulberry32). Dart's own `Random(seed)` is not
/// guaranteed to give the same numbers on every platform or Dart version, and
/// the schedule must come out identical on Windows and Android.
class SeededRandom {
  int _state;

  SeededRandom(int seed) : _state = seed & _mask;

  static const int _mask = 0xFFFFFFFF;

  int nextUint32() {
    _state = (_state + 0x6D2B79F5) & _mask;
    var t = _imul(_state ^ (_state >> 15), _state | 1);
    t = (t ^ ((t + _imul(t ^ (t >> 7), t | 61)) & _mask)) & _mask;
    return (t ^ (t >> 14)) & _mask;
  }

  /// A number in [0, max). The modulo bias is negligible for schedule sizes.
  int nextInt(int max) => nextUint32() % max;

  static int _imul(int a, int b) => (a * b) & _mask;
}

/// 32-bit FNV-1a hash of [text], used to turn "channel|date" into a seed.
int stableHash(String text) {
  var h = 0x811C9DC5;
  for (final byte in utf8.encode(text)) {
    h ^= byte;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Returns a shuffled copy of [items] (Fisher-Yates). Same seed, same order.
List<T> seededShuffle<T>(List<T> items, int seed) {
  final out = List<T>.of(items);
  final rng = SeededRandom(seed);
  for (var i = out.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}
