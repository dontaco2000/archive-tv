import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

const _font = 'Consolas';
const _panel = Color(0xF0101A5C); // the menu's blue, a little more solid: the QR needs a calm background
const _yellow = Color(0xFFFFEB3B);
final _closeKeys = {LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack, LogicalKeyboardKey.backspace, LogicalKeyboardKey.keyM, LogicalKeyboardKey.contextMenu};
final _arrows = {LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight};

/// Phone remote (Menu > Remote > Phone remote): a big QR code with the remote page's address and key, so a
/// phone on the same Wi-Fi opens the remote by scanning it. OK turns the phone remote on/off, Back/Esc/M close.
class PhoneRemoteCard extends StatefulWidget {
  static const qrKey = ValueKey('phone-remote-qr');

  /// Phones can connect (Settings.remoteLan).
  final bool on;

  /// The QR code's address (with the token); [url] is the same without it, for typing, with [pin].
  final String? qrUrl, url, pin;

  /// The network address is being looked up / the server could not start (every port busy).
  final bool finding, failed;

  /// Windows: mention the firewall question that may come up on first use.
  final bool firewallNote;

  final VoidCallback onToggle, onClose;

  const PhoneRemoteCard({
    super.key,
    required this.on,
    required this.qrUrl,
    required this.url,
    required this.pin,
    required this.onToggle,
    required this.onClose,
    this.finding = false,
    this.failed = false,
    this.firewallNote = false,
  });

  @override
  State<PhoneRemoteCard> createState() => _PhoneRemoteCardState();
}

class _PhoneRemoteCardState extends State<PhoneRemoteCard> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // As in the menu: autofocus is ignored while the TV screen holds focus.
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
    if (e is! KeyDownEvent) return e is KeyRepeatEvent ? KeyEventResult.handled : KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.select) {
      widget.onToggle();
    } else if (_closeKeys.contains(k)) {
      widget.onClose();
    } else if (_arrows.contains(k)) {
      // nothing to move between; kept here so arrows don't flip channels or the volume behind the card
    } else {
      return KeyEventResult.ignored; // volume, mute, fullscreen reach the TV screen
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget, qr = w.on ? w.qrUrl : null;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Container(
        color: _panel,
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, box) {
          final side = (box.maxHeight * 0.78).clamp(120.0, box.maxWidth * 0.5);
          final font = (box.maxHeight / 26).clamp(11.0, 34.0);
          TextStyle style(Color c, {double scale = 1, bool bold = false}) =>
              TextStyle(fontFamily: _font, fontSize: font * scale, color: c, fontWeight: bold ? FontWeight.bold : null, height: 1.25);
          final lines = <Widget>[
            Text('PHONE REMOTE', style: style(_yellow, scale: 1.5, bold: true)),
            SizedBox(height: font * 0.6),
            Text(w.on ? 'ON: phones on this Wi-Fi can connect' : 'OFF', style: style(w.on ? const Color(0xFF8DFFB0) : const Color(0xFFFF7B6B), bold: true)),
            SizedBox(height: font),
            if (!w.on)
              Text('Press OK to turn it on.', style: style(Colors.white))
            else if (w.failed)
              Text('Could not start the phone remote: ports 8765-8774 are all in use.', style: style(Colors.white))
            else if (qr == null)
              Text(
                w.finding
                    ? 'Finding this device\'s network address...'
                    : 'No network address found.\nConnect this device to your home Wi-Fi or Ethernet, then open this screen again.',
                style: style(Colors.white),
              )
            else ...[
              Text('Scan the code with your phone\'s camera. The phone must be on the same Wi-Fi.', style: style(Colors.white)),
              SizedBox(height: font),
              Text('Or open this address and type the PIN:', style: style(Colors.white70, scale: 0.85)),
              Text(w.url ?? '', style: style(_yellow, bold: true)),
              Text('PIN ${w.pin ?? '-'}', style: style(_yellow, bold: true)),
              if (w.firewallNote) ...[
                SizedBox(height: font),
                Text('If Windows asks, allow Archive TV on private networks.', style: style(Colors.white70, scale: 0.85)),
              ],
            ],
            const Spacer(),
            Text(w.on ? 'OK: turn off    Back: close' : 'OK: turn on    Back: close', style: style(Colors.white70, scale: 0.9)),
          ];
          return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            // High contrast for a camera across the room: black modules on white, a 4-module quiet zone, no logo.
            Container(
              key: PhoneRemoteCard.qrKey,
              width: side,
              height: side,
              color: qr == null ? const Color(0xFF1E2C8A) : Colors.white,
              padding: EdgeInsets.all(side * 0.09),
              alignment: Alignment.center,
              child: qr == null
                  ? Text(w.on ? '...' : 'OFF', style: style(Colors.white38, scale: 2, bold: true))
                  : QrImageView(data: qr, semanticsLabel: 'QR code: $qr', padding: EdgeInsets.zero, errorCorrectionLevel: QrErrorCorrectLevel.M, backgroundColor: Colors.white),
            ),
            SizedBox(width: font * 1.5),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(height: font), ...lines, SizedBox(height: font * 0.5)]),
            ),
          ]);
        }),
      ),
    );
  }
}
