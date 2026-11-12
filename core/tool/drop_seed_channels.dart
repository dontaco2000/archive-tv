// Removes channels from the Android seed without a rebuild (keeps the header, so builtAt is unchanged).
// From app\core:  dart run tool/drop_seed_channels.dart ../player/assets/seed_pools.jsonl.gz 22,23
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: drop_seed_channels.dart <seed.jsonl.gz> <n,n,...>');
    exit(2);
  }
  final drop = args[1].split(',').map(int.parse).toSet();
  final f = File(args[0]);
  final lines = utf8.decode(gzip.decode(f.readAsBytesSync())).split('\n').where((l) => l.trim().isNotEmpty).toList();
  final kept = [lines.first, for (final l in lines.skip(1)) if (!drop.contains((jsonDecode(l) as Map)['n'])) l];
  f.writeAsBytesSync(gzip.encode(utf8.encode('${kept.join('\n')}\n')));
  stdout.writeln('${lines.length - kept.length} channels dropped, ${kept.length - 1} left, ${f.lengthSync()} bytes');
}
