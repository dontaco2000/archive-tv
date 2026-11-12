import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Kept equal to pubspec.yaml's version by test/about_overlay_test.dart.
const appVersion = '0.9.1';

const aboutLines = [
  'All video and audio comes from the Internet Archive (archive.org) and its uploaders. '
      'Archive TV only finds and plays it; we are not responsible for the content and are not '
      'affiliated with or endorsed by the Internet Archive.',
  'Some channels (such as Headliner, Teaser and Haunt) can include mature content.',
  'Weather: WeatherStar 4000+ by Matt Walsh (MIT licence); data from Open-Meteo and the US National Weather Service.',
  'Hobby project, provided as is.',
];

/// About / content notice. As the one-time first-run notice ([firstRun]) any key closes it;
/// as the menu's About, Esc / Back / Enter / M does. A click or tap anywhere closes both.
class AboutOverlay extends StatefulWidget {
  final bool firstRun;
  final VoidCallback onClose;

  /// C opens the credits (not on the first-run notice, where any key closes).
  final VoidCallback? onCredits;
  const AboutOverlay({super.key, this.firstRun = false, required this.onClose, this.onCredits});

  @override
  State<AboutOverlay> createState() => _AboutOverlayState();
}

class _AboutOverlayState extends State<AboutOverlay> {
  final _focus = FocusNode();

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

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return widget.firstRun ? KeyEventResult.handled : KeyEventResult.ignored;
    final k = e.logicalKey;
    if (!widget.firstRun && k == LogicalKeyboardKey.keyC && widget.onCredits != null) {
      widget.onCredits!();
      return KeyEventResult.handled;
    }
    if (widget.firstRun ||
        const [
          LogicalKeyboardKey.escape,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.keyM,
          LogicalKeyboardKey.contextMenu,
        ].contains(k)) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    // Volume, mute and fullscreen still reach the TV screen.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      // A click or tap anywhere closes it too.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onClose,
        child: Center(
          child: FractionallySizedBox(
            widthFactor: 0.85,
            heightFactor: 0.85,
            child: Container(
              color: const Color(0xFA101A5C),
              padding: const EdgeInsets.all(24),
              child: LayoutBuilder(
                builder: (context, box) {
                  final font = (box.maxHeight / 36 < box.maxWidth / 44 ? box.maxHeight / 36 : box.maxWidth / 44).clamp(9.0, 24.0);
                  TextStyle style(Color c, {double scale = 1, bool bold = false}) =>
                      TextStyle(fontFamily: 'Consolas', fontSize: font * scale, color: c, fontWeight: bold ? FontWeight.bold : null);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Image.asset('assets/branding/logo.png', height: font * 5.5, filterQuality: FilterQuality.medium),
                      SizedBox(height: font * 0.4),
                      Text(
                        widget.firstRun ? 'ARCHIVE TV - PLEASE NOTE' : 'ABOUT ARCHIVE TV',
                        style: style(const Color(0xFFFFEB3B), scale: 1.3, bold: true),
                      ),
                      Text('Archive TV $appVersion', style: style(const Color(0xFF9EC8FF))),
                      SizedBox(height: font),
                      for (final l in aboutLines)
                        Padding(
                          padding: EdgeInsets.only(bottom: font * 0.8),
                          child: Text(l, style: style(Colors.white)),
                        ),
                      const Spacer(),
                      Text(
                        widget.firstRun
                            ? 'Click or press any key to continue'
                            : 'Click or press Esc to close${widget.onCredits == null ? '' : ', C for credits'}',
                        style: style(const Color(0xFFFFEB3B)),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
