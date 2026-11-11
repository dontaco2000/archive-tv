import 'dart:convert';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

List<int> bytes(List<String> boxes) => [
      0, 0, 0, 0x18,
      for (final b in boxes) ...[...ascii.encode(b), 0, 0, 0, 0],
    ];

void main() {
  test('moov before mdat is faststart, and asks for the first 64 KB', () async {
    String? range;
    final client = MockClient((req) async {
      range = req.headers['Range'];
      return http.Response.bytes(bytes(['ftyp', 'moov', 'mdat']), 206);
    });
    expect(await probeFaststart(client, 'https://x/a.mp4'), Faststart.yes);
    expect(range, 'bytes=0-65535');
  });

  test('mdat first, or no moov in range, is not faststart', () async {
    for (final boxes in [
      ['ftyp', 'mdat', 'free'],
      ['ftyp', 'mdat', 'moov'],
    ]) {
      final client = MockClient((_) async => http.Response.bytes(bytes(boxes), 206));
      expect(await probeFaststart(client, 'https://x/a.mp4'), Faststart.no);
    }
  });

  test('network errors and non-2xx are unknown', () async {
    final notFound = MockClient((_) async => http.Response('', 404));
    expect(await probeFaststart(notFound, 'https://x/a.mp4'), Faststart.unknown);
    final broken = MockClient((_) async => throw http.ClientException('boom'));
    expect(await probeFaststart(broken, 'https://x/a.mp4'), Faststart.unknown);
  });

  test('Entry round-trips faststart true/false/null', () {
    const base = Entry(
        id: 'i/f', itemId: 'i', file: 'f', title: 't', durationSeconds: 1, url: 'u');
    for (final v in [true, false, null]) {
      final e = Entry.fromJson(base.copyWith(faststart: v).toJson());
      expect(e.faststart, v);
    }
    expect(base.toJson().containsKey('faststart'), isFalse);
  });
}
