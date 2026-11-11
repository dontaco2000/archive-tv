import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/services.dart';

/// What the viewer asked for, independent of which device asked.
enum TvAction { channelUp, channelDown, digit, info, guide, menu, favorite, mute, volumeUp, volumeDown, toggleFullscreen, ok, back, onDemand, remote }

class KeyBinding {
  final TvAction action;
  final int? digit;
  const KeyBinding(this.action, [this.digit]);
}

/// Keyboard and TV-remote mapping table (Android TV's D-pad arrives as arrow keys).
final Map<LogicalKeyboardKey, KeyBinding> keyboardBindings = {
  LogicalKeyboardKey.arrowUp: const KeyBinding(TvAction.channelUp),
  LogicalKeyboardKey.pageUp: const KeyBinding(TvAction.channelUp),
  LogicalKeyboardKey.arrowDown: const KeyBinding(TvAction.channelDown),
  LogicalKeyboardKey.pageDown: const KeyBinding(TvAction.channelDown),
  LogicalKeyboardKey.keyI: const KeyBinding(TvAction.info),
  LogicalKeyboardKey.keyG: const KeyBinding(TvAction.guide),
  LogicalKeyboardKey.keyM: const KeyBinding(TvAction.menu),
  LogicalKeyboardKey.keyF: const KeyBinding(TvAction.favorite),
  LogicalKeyboardKey.keyU: const KeyBinding(TvAction.mute),
  LogicalKeyboardKey.space: const KeyBinding(TvAction.mute),
  LogicalKeyboardKey.equal: const KeyBinding(TvAction.volumeUp),
  LogicalKeyboardKey.minus: const KeyBinding(TvAction.volumeDown),
  LogicalKeyboardKey.f11: const KeyBinding(TvAction.toggleFullscreen),
  LogicalKeyboardKey.keyO: const KeyBinding(TvAction.onDemand),
  LogicalKeyboardKey.keyR: const KeyBinding(TvAction.remote), // Windows: opens / closes the remote window
  LogicalKeyboardKey.enter: const KeyBinding(TvAction.ok),
  LogicalKeyboardKey.escape: const KeyBinding(TvAction.back),
  // Android TV / Fire TV remote. Select opens the guide when no digits are pending, and Back
  // arrives as a route pop, not a key (both in TvScreen).
  LogicalKeyboardKey.select: const KeyBinding(TvAction.ok),
  LogicalKeyboardKey.contextMenu: const KeyBinding(TvAction.menu),
  LogicalKeyboardKey.mediaPlayPause: const KeyBinding(TvAction.mute),
  LogicalKeyboardKey.channelUp: const KeyBinding(TvAction.channelUp),
  LogicalKeyboardKey.channelDown: const KeyBinding(TvAction.channelDown),
  LogicalKeyboardKey.mediaFastForward: const KeyBinding(TvAction.channelUp),
  LogicalKeyboardKey.mediaRewind: const KeyBinding(TvAction.channelDown),
  LogicalKeyboardKey.arrowRight: const KeyBinding(TvAction.volumeUp),
  LogicalKeyboardKey.arrowLeft: const KeyBinding(TvAction.volumeDown),
  LogicalKeyboardKey.digit0: const KeyBinding(TvAction.digit, 0),
  LogicalKeyboardKey.digit1: const KeyBinding(TvAction.digit, 1),
  LogicalKeyboardKey.digit2: const KeyBinding(TvAction.digit, 2),
  LogicalKeyboardKey.digit3: const KeyBinding(TvAction.digit, 3),
  LogicalKeyboardKey.digit4: const KeyBinding(TvAction.digit, 4),
  LogicalKeyboardKey.digit5: const KeyBinding(TvAction.digit, 5),
  LogicalKeyboardKey.digit6: const KeyBinding(TvAction.digit, 6),
  LogicalKeyboardKey.digit7: const KeyBinding(TvAction.digit, 7),
  LogicalKeyboardKey.digit8: const KeyBinding(TvAction.digit, 8),
  LogicalKeyboardKey.digit9: const KeyBinding(TvAction.digit, 9),
};

/// The channel [step] away from [current] (wrapping) among [tunable]; with [favoritesOnly],
/// only favorites are visited, unless none of the tunable channels is a favorite.
Channel? flipTarget(List<Channel> tunable, int? current, int step, {Set<int> favorites = const {}, bool favoritesOnly = false}) {
  var list = tunable;
  if (favoritesOnly) {
    final favs = [for (final c in tunable) if (favorites.contains(c.number)) c];
    if (favs.isNotEmpty) list = favs;
  }
  if (list.isEmpty) return null;
  final i = list.indexWhere((c) => c.number == current);
  return list[((i < 0 ? (step > 0 ? -1 : 0) : i) + step) % list.length];
}

/// Accumulates digits into a channel number (last three digits kept).
/// The screen commits it after a pause or on OK.
class NumberEntry {
  String _text = '';
  String get text => _text;

  void add(int digit) {
    final t = '$_text$digit';
    _text = t.length > 3 ? t.substring(t.length - 3) : t;
  }

  /// The entered channel number, clearing the buffer; null if nothing was entered.
  int? commit() {
    final n = int.tryParse(_text);
    _text = '';
    return n;
  }

  void clear() => _text = '';
}
