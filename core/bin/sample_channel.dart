import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:archive_tv_core/archive_tv_core.dart';

/// Usage: `dart run bin/sample_channel.dart CHANNELS_JSON CHANNEL_NUMBER [ITEMS]`
/// Builds the channel's pool from real Archive and prints what it found plus
/// the next 12 hours of guide.
Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: sample_channel CHANNELS_JSON CHANNEL_NUMBER [ITEMS]');
    exit(64);
  }
  final config = parseChannelConfig(File(args[0]).readAsStringSync());
  final channel = config.channel(int.parse(args[1]));
  if (channel == null) {
    stderr.writeln('no channel ${args[1]} in ${args[0]}');
    exit(64);
  }
  final items = args.length > 2 ? int.parse(args[2]) : 30;

  final api = ArchiveClient();
  final probe = http.Client();
  final pool = await buildPool(channel, config, api, itemsPerSource: items, probeClient: probe, log: print);
  final hours = pool.fold(0.0, (s, e) => s + e.durationSeconds) / 3600;
  print('${channel.number} ${channel.name}: ${pool.length} entries, ${hours.toStringAsFixed(1)} h'
      '${isOffAir(pool, config.minContentSeconds) ? '  (OFF AIR)' : ''}');
  print('  faststart yes/no/unknown: ${pool.where((e) => e.faststart == true).length}/'
      '${pool.where((e) => e.faststart == false).length}/${pool.where((e) => e.faststart == null).length}');
  final foreign = pool.where((e) => e.foreign).toList();
  final itemCount = {for (final e in pool) e.itemId}.length;
  final foreignItems = {for (final e in foreign) e.itemId}.length;
  final noSide = {for (final e in foreign) if (e.subUrl == null) e.itemId}.length;
  print('  items $itemCount, foreign items $foreignItems (entries ${foreign.length}), foreign items without an English sidecar $noSide, '
      'entries with any English sidecar ${pool.where((e) => e.subUrl != null).length}, silent ${pool.where((e) => e.silent).length}');
  print('  comprehensible ${(pool.where(comprehensible).fold(0.0, (s, e) => s + e.durationSeconds) / 3600).toStringAsFixed(1)} h; '
      'languages: ${{for (final e in foreign) e.language}.join(' | ')}');
  for (final e in pool.take(8)) {
    print('  ${(e.durationSeconds / 60).round().toString().padLeft(4)} min  ${e.title}  ${e.url}');
  }

  final now = DateTime.now();
  for (final s in guide(now, (d) => scheduleDay(pool, 'ch${channel.number}', d), hours: 12).take(6)) {
    final t = '${s.start.hour.toString().padLeft(2, '0')}:${s.start.minute.toString().padLeft(2, '0')}';
    print('  $t  ${s.entry.title}');
  }
  probe.close();
  api.close();
}
