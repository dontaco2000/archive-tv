import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';

/// Channel logo from assets/logos (lowercased name, no spaces or hyphens, .png); falls back to the name as text.
class ChannelLogo extends StatelessWidget {
  final Channel channel;
  final double? height;
  const ChannelLogo({super.key, required this.channel, this.height});

  @override
  Widget build(BuildContext context) {
    final key = channel.name.toLowerCase().replaceAll(RegExp(r'[\s-]'), '');
    return Image.asset('assets/logos/$key.png',
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Text(channel.name,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontFamily: 'Consolas', fontWeight: FontWeight.bold)));
  }
}
