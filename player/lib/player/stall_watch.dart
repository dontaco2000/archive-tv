/// Says when playback has stopped moving: the position has not changed for [limit]
/// while the player was supposed to be playing.
class StallWatch {
  final Duration limit;
  Duration? _last;
  DateTime _since;

  StallWatch({this.limit = const Duration(seconds: 8), required DateTime now}) : _since = now;

  /// Feed the current [position] at [now]; true once it has been stuck for longer than [limit].
  bool check(Duration position, DateTime now, {bool paused = false}) {
    if (paused || position != _last) {
      _last = position;
      _since = now;
      return false;
    }
    return now.difference(_since) > limit;
  }
}
