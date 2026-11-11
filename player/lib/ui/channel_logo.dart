import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';

/// The logo asset for a channel name: lowercased, no spaces or hyphens, .png.
String logoAsset(String channelName) => 'assets/logos/${channelName.toLowerCase().replaceAll(RegExp(r'[\s-]'), '')}.png';

/// Channel logo from assets/logos (see [logoAsset]); falls back to the name as text.
class ChannelLogo extends StatelessWidget {
  final Channel channel;
  final double? height;
  const ChannelLogo({super.key, required this.channel, this.height});

  @override
  Widget build(BuildContext context) {
    return Image.asset(logoAsset(channel.name),
        height: height,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Text(channel.name,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontFamily: 'Consolas', fontWeight: FontWeight.bold)));
  }
}
