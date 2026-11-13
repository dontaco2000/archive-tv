import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'about_overlay.dart';

typedef Credit = ({String name, String what, String url});

/// External credits. Same wording as _build/credits-text.md (for the README).
const credits = <Credit>[
  (name: 'Internet Archive', what: 'All video and audio (archive.org and its uploaders). Not affiliated with or endorsed by the Internet Archive.', url: 'https://archive.org'),
  (name: 'WeatherStar 4000+ by Matt Walsh', what: 'The weather channel page (MIT licence).', url: 'https://weatherstar.netbymatt.com'),
  (name: 'Open-Meteo', what: 'Weather data and place search.', url: 'https://open-meteo.com'),
  (name: 'National Weather Service', what: 'US weather data (via WeatherStar 4000+).', url: 'https://www.weather.gov'),
  (name: 'media_kit / libmpv', what: 'Video and audio playback (mpv, FFmpeg).', url: 'https://mpv.io'),
  (name: 'Flutter', what: 'App framework.', url: 'https://flutter.dev'),
  (name: 'flutter_inappwebview / Microsoft WebView2', what: 'Shows the weather page.', url: 'https://inappwebview.dev'),
];

const creditsDisclaimer = 'We are not responsible for the content: Archive TV only finds and plays what the Internet Archive '
    'hosts. Some channels (such as Headliner, Teaser and Haunt) can include mature content.';

/// Opens [target] (a web address or a folder) with Windows' default handler. Other platforms: nothing.
Future<void> openExternal(String target, void Function(String) log) async {
  if (!Platform.isWindows) return;
  try {
    await Process.start('explorer.exe', [target]); // default browser for a URL, Explorer for a folder
  } on Object catch (e) {
    log('open $target failed: $e');
  }
}

/// Credits list. Up/Down select, Enter or a click opens the link in the default browser (Windows; on Android TV
/// the links are only shown). Esc / Back / M closes.
class CreditsOverlay extends StatefulWidget {
  final VoidCallback onClose;
  final void Function(String) log;
  const CreditsOverlay({super.key, required this.onClose, required this.log});

  @override
  State<CreditsOverlay> createState() => _CreditsOverlayState();
}

class _CreditsOverlayState extends State<CreditsOverlay> {
  final _focus = FocusNode();
  int _sel = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _open(int i) => unawaited(openExternal(credits[i].url, widget.log));

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      setState(() => _sel = (_sel + (k == LogicalKeyboardKey.arrowUp ? -1 : 1)) % credits.length);
    } else if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) {
      _open(_sel);
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.keyM || k == LogicalKeyboardKey.contextMenu) {
      widget.onClose();
    } else {
      return KeyEventResult.ignored; // volume, mute, fullscreen reach the TV screen
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _focus,
    autofocus: true,
    onKeyEvent: _onKey,
    child: Center(
      child: FractionallySizedBox(
        widthFactor: 0.9,
        heightFactor: 0.9,
        child: Container(
          color: const Color(0xFA101A5C),
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(
            builder: (context, box) {
              final font = (box.maxHeight / 42 < box.maxWidth / 56 ? box.maxHeight / 42 : box.maxWidth / 56).clamp(7.0, 20.0);
              TextStyle style(Color c, {double scale = 1, bool bold = false, bool link = false}) => TextStyle(
                fontFamily: 'Consolas',
                fontSize: font * scale,
                color: c,
                fontWeight: bold ? FontWeight.bold : null,
                decoration: link ? TextDecoration.underline : null,
                decorationColor: c,
              );
              final windows = Platform.isWindows;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('CREDITS', style: style(const Color(0xFFFFEB3B), scale: 1.3, bold: true)),
                  Text('Archive TV $appVersion', style: style(const Color(0xFF9EC8FF))),
                  SizedBox(height: font * 0.6),
                  for (final (i, c) in credits.indexed)
                    MouseRegion(
                      cursor: windows ? SystemMouseCursors.click : MouseCursor.defer,
                      child: GestureDetector(
                        onTap: () {
                          setState(() => _sel = i);
                          _open(i);
                        },
                        child: Container(
                          width: double.infinity,
                          margin: EdgeInsets.only(bottom: font * 0.3),
                          padding: EdgeInsets.symmetric(horizontal: font * 0.4, vertical: font * 0.15),
                          color: i == _sel ? const Color(0xFF1E2C8A) : Colors.transparent,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text.rich(TextSpan(children: [
                                TextSpan(text: c.name, style: style(Colors.white, bold: true)),
                                const TextSpan(text: '  '),
                                TextSpan(text: c.url.replaceFirst('https://', ''), style:style(const Color(0xFF7FD8FF), link: windows)),
                              ])),
                              Text(c.what, style: style(const Color(0xFFCCCCCC), scale: 0.85)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  SizedBox(height: font * 0.4),
                  Text(creditsDisclaimer, style: style(const Color(0xFFFFE08A), scale: 0.85)),
                  const Spacer(),
                  Text(
                    windows ? 'Up/Down select, Enter or click: open link, Esc: close' : 'Up/Down select, Back: close',
                    style: style(const Color(0xFFFFEB3B)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}
