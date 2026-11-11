import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;

/// Usage: `dart run bin/probe_latency.dart CHANNELS_JSON CHANNEL_NUMBER`
/// For a few entries of the channel, times how long Archive takes to start
/// sending the file (first byte of a ranged request) and to deliver the first 1 MB.
Future<void> main(List<String> args) async {
  final config = parseChannelConfig(File(args[0]).readAsStringSync());
  final channel = config.channel(int.parse(args[1]))!;
  final api = ArchiveClient();
  final pool = await buildPool(channel, config, api, itemsPerSource: 5);
  final client = http.Client();
  for (final e in pool.take(5)) {
    final sw = Stopwatch()..start();
    final req = http.Request('GET', Uri.parse(e.url))..headers['Range'] = 'bytes=0-1048575';
    try {
      final res = await client.send(req).timeout(const Duration(seconds: 20));
      final headMs = sw.elapsedMilliseconds;
      final bytes = (await res.stream.toBytes()).length;
      print('${res.statusCode}  first byte $headMs ms, ${bytes ~/ 1024} KB in ${sw.elapsedMilliseconds} ms  ${e.id}');
    } catch (err) {
      print('FAILED after ${sw.elapsedMilliseconds} ms  ${e.id}: $err'); // a slow server is data, not a crash
    }
  }
  client.close();
  api.close();
}
