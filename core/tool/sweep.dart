import 'dart:convert';
import 'dart:io';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;

/// Usage (from app\core, copied to tool\): dart run tool/sweep.dart CHANNELS_JSON OUT_DIR CACHE_DIR [n,n,...]
/// Builds every channel's pool exactly as the app does (no faststart probes), item metadata cached on disk so
/// re-runs after edits only fetch new items. OUT_DIR/<n>.tsv: source, minutes, item, language, title.
class CachingClient extends http.BaseClient {
  final http.Client inner = http.Client();
  final Directory dir;
  CachingClient(this.dir);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final isMeta = request.url.path.startsWith('/metadata/');
    final f = File('${dir.path}/${Uri.encodeComponent(request.url.path.substring(10))}.json');
    if (isMeta && f.existsSync()) {
      return http.StreamedResponse(Stream.value(f.readAsBytesSync()), 200);
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final res = await inner.send(request);
    if (!isMeta || res.statusCode != 200) return res;
    final bytes = await res.stream.toBytes();
    f.writeAsBytesSync(bytes);
    return http.StreamedResponse(Stream.value(bytes), 200);
  }
}

class Tracking implements ArchiveApi {
  final ArchiveApi inner;
  final List<Source> sources;
  final sourceOf = <String, int>{};
  Tracking(this.inner, this.sources);
  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async {
    final i = sources.indexWhere((s) => s.query != null && query.contains(s.query!));
    final hits = await inner.search(query, rows: rows, page: page);
    for (final h in hits) {
      sourceOf.putIfAbsent(h.identifier, () => i);
    }
    return hits;
  }

  @override
  Future<ItemMeta?> metadata(String id) => inner.metadata(id);
}

Future<void> main(List<String> a) async {
  final config = parseChannelConfig(File(a[0]).readAsStringSync());
  final out = Directory(a[1])..createSync(recursive: true);
  final cache = Directory(a[2])..createSync(recursive: true);
  final only = a.length > 3 ? a[3].split(',').map(int.parse).toSet() : null;
  final client = ArchiveClient(client: CachingClient(cache));
  for (final ch in config.channels) {
    if (only != null && !only.contains(ch.number)) continue;
    if (ch.sources.isEmpty) continue;
    final api = Tracking(client, ch.sources);
    final sw = Stopwatch()..start();
    final pool = await buildPool(ch, config, api, concurrency: 4, log: (m) => stderr.writeln(m));
    final h = pool.fold(0.0, (s, e) => s + e.durationSeconds) / 3600;
    print('${ch.number} ${ch.name}: ${pool.length} entries, ${h.toStringAsFixed(1)} h, ${sw.elapsed.inSeconds} s');
    File('${out.path}/${ch.number}.tsv').writeAsStringSync(const LineSplitter()
        .convert([
          for (final e in pool)
            '${api.sourceOf[e.itemId]}\t${(e.durationSeconds / 60).toStringAsFixed(1)}\t${e.itemId}\t${e.language ?? ''}\t${e.title.replaceAll('\t', ' ')}\t${e.file}'
        ].join('\n'))
        .join('\n'));
  }
  client.close();
}
