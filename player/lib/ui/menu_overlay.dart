import 'dart:async';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/picture.dart';
import '../settings/settings_store.dart';

const _font = 'Consolas';
const _panel = Color(0xE6101A5C); // same dark translucent blue as the guide
const _yellow = Color(0xFFFFEB3B);
const _cellBg = Color(0xFF1E2C8A);

enum _Item { back, onDemand, favorite, favoritesOnly, volume, mute, leveling, captions, captionSize, picture, startFullscreen, cornerBug, block, wrongChannel, sleep, refresh, weatherMode, weatherLocation, openRemote, remoteLan, remoteInfo, parental, lastError, openLog, openSettings, credits, about, close }

/// Top-level categories, in menu order, and the items each one opens.
enum _Cat {
  channels('Channels & Guide', [_Item.onDemand, _Item.favorite, _Item.favoritesOnly, _Item.refresh]),
  pictureSound('Picture & Sound', [_Item.volume, _Item.mute, _Item.leveling, _Item.picture, _Item.captions, _Item.captionSize, _Item.startFullscreen, _Item.cornerBug]),
  weather('Weather', [_Item.weatherMode, _Item.weatherLocation]),
  remote('Remote', [_Item.openRemote, _Item.remoteLan, _Item.remoteInfo]),
  tools('Sleep & Tools', [_Item.sleep, _Item.wrongChannel, _Item.block, _Item.lastError, _Item.openLog, _Item.openSettings]),
  about('About & Credits', [_Item.about, _Item.credits]);

  final String title;
  final List<_Item> items;
  const _Cat(this.title, this.items);
}

/// '3:42 PM'.
String menuClock(DateTime t) =>
    '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';

/// "Last error: none", or its first line (the menu clips it); Enter copies the whole text.
String lastErrorLabel(String? e) {
  if (e == null || e.trim().isEmpty) return 'Last error: none';
  final first = e.trim().split('\n').first.replaceFirst(RegExp(r'^\S+ '), ''); // drop the timestamp
  return 'Last error (Enter: copy): $first';
}

/// Settings menu over the right half of the frame. Changes are made on [settings] in place
/// and reported through [onChanged]; the screen saves and applies them.
class MenuOverlay extends StatefulWidget {
  static const selectedKey = ValueKey('menu-selected');
  static const clockKey = ValueKey('menu-clock');
  static const banner = 'assets/branding/banner.png';

  final Settings settings;
  final Channel? current;
  final void Function(Settings) onChanged;
  final VoidCallback onBlockCurrent;
  final VoidCallback onRefresh;
  final VoidCallback onClose;
  final VoidCallback? onOnDemand;
  final VoidCallback? onWeatherLocation;
  final VoidCallback? onAbout;
  final VoidCallback? onCredits;

  /// The last uncaught error (null: none); Enter copies it ([onCopyLastError]).
  final String? lastError;
  final VoidCallback? onCopyLastError;

  /// Windows only: opens the folder with archive_tv.log (null hides the item).
  final VoidCallback? onOpenLogFolder;

  /// False when the player's libmpv can't build the leveling filters.
  final bool levelingAvailable;

  /// Windows only: opens / closes the remote window (null hides the remote items).
  final VoidCallback? onOpenRemote;

  /// Whether the remote window is open (the remote item shows ON/OFF and toggles it).
  final bool remoteOpen;

  /// The phone address and PIN, shown while the remote is on Wi-Fi.
  final String? remoteLanInfo;

  /// "Wrong channel for this program": skip it and keep it off this channel (null hides the item).
  final VoidCallback? onWrongChannel;

  /// Steps the sleep timer (null hides the item); [sleepStep] is the chosen step (0 off), [sleepLeft] minutes left.
  final VoidCallback? onSleep;
  final int sleepStep;
  final int? sleepLeft;

  /// Opens Parental controls (null hides the item).
  final VoidCallback? onParental;

  /// Windows only: opens archive_tv_settings.txt in Notepad (null hides the item).
  final VoidCallback? onOpenSettingsFile;

  const MenuOverlay({
    this.onParental,
    this.onOpenSettingsFile,
    super.key,
    required this.settings,
    required this.current,
    required this.onChanged,
    required this.onBlockCurrent,
    required this.onRefresh,
    required this.onClose,
    this.onOnDemand,
    this.onWeatherLocation,
    this.onAbout,
    this.onCredits,
    this.lastError,
    this.onCopyLastError,
    this.onOpenLogFolder,
    this.levelingAvailable = true,
    this.onOpenRemote,
    this.remoteLanInfo,
    this.remoteOpen = false,
    this.onWrongChannel,
    this.onSleep,
    this.sleepStep = 0,
    this.sleepLeft,
  });

  @override
  State<MenuOverlay> createState() => MenuOverlayState();
}

class MenuOverlayState extends State<MenuOverlay> {
  final _focus = FocusNode();
  final _scroll = ScrollController();
  int _sel = 0;
  _Cat? _cat; // null: the top level

  // Android TV is always fullscreen, so its menu has no window-mode item; the remote is Windows only.
  bool _shown(_Item i) =>
      !(Platform.isAndroid && i == _Item.startFullscreen) &&
      !(widget.onOpenRemote == null && (i == _Item.openRemote || i == _Item.remoteLan)) &&
      !(widget.remoteLanInfo == null && i == _Item.remoteInfo) &&
      !(widget.onOpenLogFolder == null && i == _Item.openLog) &&
      !(widget.onWrongChannel == null && i == _Item.wrongChannel) &&
      !(widget.onSleep == null && i == _Item.sleep) &&
      !(widget.onParental == null && i == _Item.parental) &&
      !(widget.onOpenSettingsFile == null && i == _Item.openSettings);

  /// Rows of the current level: a [_Cat] opens it, an [_Item] acts. Parental controls sits
  /// on the top level itself (its own screen is the sub-menu).
  List<Object> get _rows {
    final c = _cat;
    if (c != null) return [_Item.back, ...c.items.where(_shown)];
    return [
      for (final cat in _Cat.values)
        if (cat.items.any(_shown)) cat,
      if (_shown(_Item.parental)) _Item.parental,
      _Item.close,
    ];
  }

  Settings get s => widget.settings;

  /// Back / Esc: up one level. False at the top level (the caller closes the menu).
  bool back() {
    final c = _cat;
    if (c == null) return false;
    setState(() {
      _cat = null;
      _sel = _rows.indexOf(c); // back on the category's own row
    });
    return true;
  }

  /// Scrolls just enough to keep row [_sel] (height [rowH]) in view.
  void _keepVisible(double rowH) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position, top = _sel * rowH;
    if (top < p.pixels) {
      _scroll.jumpTo(top);
    } else if (top + rowH > p.pixels + p.viewportDimension) {
      _scroll.jumpTo((top + rowH - p.viewportDimension).clamp(0.0, p.maxScrollExtent));
    }
  }

  @override
  void initState() {
    super.initState();
    // autofocus is ignored when the TV screen already holds focus, so take it explicitly.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _change(void Function() f) {
    setState(f);
    widget.onChanged(s);
  }

  /// Left/Right (dir -1/+1) or Enter (dir 0) on the selected item.
  void _activate(int dir) {
    final row = _rows[_sel];
    if (row is _Cat) {
      if (dir >= 0) {
        setState(() {
          _cat = row;
          _sel = 1; // first item, under Back
        });
      }
      return;
    }
    switch (row as _Item) {
      case _Item.back:
        if (dir == 0) back();
      case _Item.volume:
        if (dir != 0) _change(() => s.volume = (s.volume + 5 * dir).clamp(0, 100).toDouble());
      case _Item.favorite:
        final c = widget.current;
        if (c != null) _change(() => toggleFavorite(s, c.number));
      case _Item.favoritesOnly:
        _change(() => s.favoritesOnly = !s.favoritesOnly);
      case _Item.mute:
        _change(() => s.muted = !s.muted);
      case _Item.startFullscreen:
        _change(() => s.startFullscreen = !s.startFullscreen);
      case _Item.cornerBug:
        _change(() => s.cornerBug = !s.cornerBug);
      case _Item.block:
        if (dir == 0) widget.onBlockCurrent();
      case _Item.wrongChannel:
        if (dir == 0) widget.onWrongChannel?.call();
      case _Item.sleep:
        widget.onSleep?.call(); // Enter, Left and Right all step it
      case _Item.refresh:
        if (dir == 0) widget.onRefresh();
      case _Item.close:
        if (dir == 0) widget.onClose();
      case _Item.onDemand:
        if (dir == 0) widget.onOnDemand?.call();
      case _Item.weatherMode:
        _change(() => s.weatherMode = s.weatherMode == 'native' ? 'web' : 'native');
      case _Item.weatherLocation:
        if (dir == 0) widget.onWeatherLocation?.call();
      case _Item.openRemote:
        if (dir == 0) widget.onOpenRemote?.call();
      case _Item.remoteLan:
        _change(() => s.remoteLan = !s.remoteLan);
      case _Item.remoteInfo:
        break;
      case _Item.leveling:
        _change(() => s.volumeLeveling = cycleLeveling(s.volumeLeveling, dir == 0 ? 1 : dir));
      case _Item.about:
        if (dir == 0) widget.onAbout?.call();
      case _Item.credits:
        if (dir == 0) widget.onCredits?.call();
      case _Item.openLog:
        if (dir == 0) widget.onOpenLogFolder?.call();
      case _Item.parental:
        if (dir == 0) widget.onParental?.call();
      case _Item.openSettings:
        if (dir == 0) widget.onOpenSettingsFile?.call();
      case _Item.lastError:
        if (dir == 0) widget.onCopyLastError?.call();
      case _Item.captions:
        _change(() => s.captionsOn = !s.captionsOn);
      case _Item.picture:
        _change(() => s.picture = cyclePicture(s.picture, dir == 0 ? 1 : dir));
      case _Item.captionSize:
        // Left/Right step and stop at the ends; Enter steps up and wraps.
        _change(() => s.captionSize = dir == 0 ? s.captionSize % 7 + 1 : (s.captionSize + dir).clamp(1, 7));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    final rows = _rows, n = rows.length;
    if (k == LogicalKeyboardKey.arrowUp) {
      setState(() => _sel = (_sel - 1) % n);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + 1) % n);
    } else if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
      // Only the volume repeats while held; toggles flip once per press.
      if (!repeat || rows[_sel] == _Item.volume || rows[_sel] == _Item.captionSize) _activate(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) {
      if (!repeat) _activate(0);
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack || k == LogicalKeyboardKey.backspace) {
      if (!repeat && !back()) widget.onClose();
    } else if (k == LogicalKeyboardKey.keyM || k == LogicalKeyboardKey.contextMenu) {
      if (!repeat) widget.onClose();
    } else {
      return KeyEventResult.ignored; // F, volume, mute, fullscreen fall through to the TV screen
    }
    return KeyEventResult.handled;
  }

  String _onOff(bool b) => b ? 'ON' : 'OFF';

  String _label(Object row) {
    if (row is _Cat) return '${row.title}  >';
    final c = widget.current;
    return switch (row as _Item) {
      _Item.back => '<  Back',
      _Item.favorite => c == null ? 'Favorite: -' : 'Favorite ${c.number} ${c.name}: ${s.favorites.contains(c.number) ? 'YES' : 'NO'}',
      _Item.favoritesOnly => 'Flip favorites only: ${_onOff(s.favoritesOnly)}',
      _Item.volume => 'Volume ${'#' * (s.volume ~/ 5)}${'.' * (20 - s.volume ~/ 5)} ${s.volume.round()}',
      _Item.mute => 'Mute: ${_onOff(s.muted)}',
      _Item.leveling => 'Volume leveling: ${s.volumeLeveling.toUpperCase()}${widget.levelingAvailable ? '' : ' (not available)'}',
      _Item.about => 'About',
      _Item.credits => 'Credits',
      _Item.openLog => 'Open log folder',
      _Item.parental => 'Parental controls: ${!s.parental.hasPin ? 'OFF' : s.parental.lockOn ? 'LOCK ON' : 'LOCK OFF'}',
      _Item.openSettings => 'Open settings file',
      _Item.lastError => lastErrorLabel(widget.lastError),
      _Item.captions => 'Captions: ${_onOff(s.captionsOn)}',
      _Item.captionSize => 'Caption size ${'#' * s.captionSize}${'.' * (7 - s.captionSize)} ${s.captionSize}',
      _Item.picture => 'Picture: ${s.picture.toUpperCase()}',
      _Item.startFullscreen => 'Start fullscreen: ${_onOff(s.startFullscreen)}',
      _Item.cornerBug => 'Corner bug: ${_onOff(s.cornerBug)}',
      _Item.block => 'Block this item',
      _Item.wrongChannel => 'Wrong channel for this program',
      _Item.sleep => widget.sleepStep == 0 ? 'Sleep timer: OFF' : 'Sleep timer: ${widget.sleepStep} MIN (${widget.sleepLeft ?? widget.sleepStep} min left)',
      _Item.refresh => 'Refresh channels',
      _Item.close => 'Close',
      _Item.onDemand => 'On Demand',
      _Item.weatherMode => 'Weather view: ${s.weatherMode == 'native' ? 'CLASSIC' : 'WEATHERSTAR'}',
      _Item.weatherLocation => 'Weather: ${s.weatherPlace}',
      _Item.openRemote => 'Remote window: ${_onOff(widget.remoteOpen)}',
      _Item.remoteLan => 'Remote on Wi-Fi: ${_onOff(s.remoteLan)}',
      _Item.remoteInfo => widget.remoteLanInfo ?? '',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: 0.55,
          heightFactor: 0.9,
          child: Container(
            color: _panel,
            padding: const EdgeInsets.all(8),
            child: LayoutBuilder(builder: (context, box) {
              // Row size follows the panel, not the item count: about 12 rows tall, never tiny;
              // a level that doesn't fit scrolls (the selected row is kept in view).
              final unit = (box.maxHeight / 12).clamp(26.0, 64.0);
              final font = (unit * 0.5).clamp(13.0, 30.0);
              final rows = _rows;
              _sel = _sel.clamp(0, rows.length - 1); // items can hide while open (remote info)
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _keepVisible(unit);
              });
              TextStyle style(Color color, {bool bold = false}) =>
                  TextStyle(fontFamily: _font, fontSize: font, color: color, fontWeight: bold ? FontWeight.bold : null);
              return Column(children: [
                Image.asset(MenuOverlay.banner, height: unit * 1.5, filterQuality: FilterQuality.medium),
                SizedBox(
                  height: unit * 0.9,
                  child: Center(child: _Clock(style: style(_yellow, bold: true))),
                ),
                if (_cat case final c?)
                  SizedBox(
                    height: unit,
                    child: Align(alignment: Alignment.centerLeft, child: Text(c.title.toUpperCase(), style: style(_yellow, bold: true))),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: Column(children: [
                      for (final (i, row) in rows.indexed)
                        Container(
                          key: i == _sel ? MenuOverlay.selectedKey : null,
                          height: unit - 2,
                          margin: const EdgeInsets.all(1),
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.centerLeft,
                          color: i == _sel ? _yellow : _cellBg,
                          // A label too wide for a small window shrinks a little rather than being cut.
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _label(row),
                              maxLines: 1,
                              softWrap: false,
                              style: style(i == _sel ? Colors.black : Colors.white, bold: i == _sel),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

/// The current time ('3:42 PM'), re-read every second so the minute flips on time.
class _Clock extends StatefulWidget {
  final TextStyle style;
  const _Clock({required this.style});

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(menuClock(DateTime.now()), key: MenuOverlay.clockKey, style: widget.style);
}
