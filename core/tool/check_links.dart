// Live smoke test of the dead-link check: HEADs the first N files of a saved pool (plus a made-up item and a made-up file that
// must both miss), 1 at a time with a 1 s pause. Writes nothing.
//   dart run tool/check_links.dart <pool-N.json> [count=15]
import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> args) async {
  final j = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final n = args.length > 1 ? int.parse(args[1]) : 15;
  final entries = [for (final e in (j['entries'] as List).take(n)) Entry.fromJson(e as Map<String, dynamic>)];
  final urls = [
    ...entries.map((e) => e.url),
    'https://archive.org/download/archive-tv-no-such-item-xyz/none.mp4',
    if (entries.isNotEmpty) 'https://archive.org/download/${entries.first.itemId}/archive-tv-no-such-file.mp4',
  ];
  final client = http.Client();
  for (final u in urls) {
    final sw = Stopwatch()..start();
    final (r, code) = await checkLink(client, u);
    print('${r.name.padRight(12)} ${code ?? '-'}  ${sw.elapsedMilliseconds} ms  $u');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  client.close();
}
