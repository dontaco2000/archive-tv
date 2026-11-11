import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Whether an mp4's `moov` index sits in the first 64 KB (fast to start).
enum Faststart { yes, no, unknown }

/// Fetches the first 64 KB of [url]; `yes` if `moov` comes before `mdat`,
/// `no` if `mdat` comes first or there is no `moov`, `unknown` on any failure.
Future<Faststart> probeFaststart(http.Client client, String url,
    {Duration timeout = const Duration(seconds: 10)}) async {
  try {
    final res = await client
        .get(Uri.parse(url), headers: {'Range': 'bytes=0-65535'}).timeout(timeout);
    if (res.statusCode < 200 || res.statusCode > 299) return Faststart.unknown;
    final text = latin1.decode(res.bodyBytes);
    final moov = text.indexOf('moov');
    final mdat = text.indexOf('mdat');
    return moov >= 0 && (mdat < 0 || moov < mdat) ? Faststart.yes : Faststart.no;
  } on TimeoutException {
    return Faststart.unknown;
  } on http.ClientException {
    return Faststart.unknown;
  }
}
