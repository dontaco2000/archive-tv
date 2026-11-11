import 'dart:async';
import 'dart:io';

import 'package:archive_tv_core/src/archive_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

ArchiveClient clientFor(MockClientHandler handler,
        {int maxAttempts = 3, Duration requestTimeout = const Duration(seconds: 30)}) =>
    ArchiveClient(
      requestTimeout: requestTimeout,
      client: MockClient(handler),
      retryDelay: Duration.zero,
      maxAttempts: maxAttempts,
    );

void main() {
  test('search sends the query and parses the real response shape', () async {
    late Uri seen;
    late Map<String, String> headers;
    final client = clientFor((req) async {
      seen = req.url;
      headers = req.headers;
      return http.Response(fixture('search.json'), 200);
    });

    final items = await client.search('collection:computerchronicles', rows: 3, page: 2);

    expect(seen.host, 'archive.org');
    expect(seen.path, '/advancedsearch.php');
    expect(seen.queryParameters['q'], 'collection:computerchronicles');
    expect(seen.queryParameters['rows'], '3');
    expect(seen.queryParameters['page'], '2');
    expect(seen.queryParametersAll['fl[]'], ['identifier', 'title', 'date', 'downloads']);
    expect(seen.queryParameters['sort[]'], 'downloads desc');
    expect(headers['User-Agent'], contains('ArchiveTV'));
    expect(items.map((i) => i.identifier), ['CC517_commodore_64', 'GaryKild', 'CC501_hypercard']);
    expect(items.first.title, 'Commodore 64');
    expect(items.first.downloads, 200366);
  });

  test('metadata parses files with sizes and lengths', () async {
    final client = clientFor((req) async {
      expect(req.url.path, '/metadata/comdex_2');
      return http.Response(fixture('meta_single.json'), 200);
    });

    final meta = (await client.metadata('comdex_2'))!;

    expect(meta.title, 'Comdex 1987');
    expect(meta.mediatype, 'movies');
    final mp4 = meta.files.firstWhere((f) => f.name == 'comdex_2_512kb.mp4');
    expect(mp4.format, '512Kb MPEG4');
    expect(mp4.size, 128125571);
    expect(mp4.length, closeTo(1763.26, 0.001));
  });

  test('metadata returns null for an unknown item (Archive answers {})', () async {
    final client = clientFor((req) async => http.Response('{}', 200));
    expect(await client.metadata('nope'), isNull);
  });

  test('retries on 429 then succeeds', () async {
    var calls = 0;
    final client = clientFor((req) async {
      calls++;
      return calls < 3 ? http.Response('slow down', 429) : http.Response('{}', 200);
    });
    expect(await client.metadata('x'), isNull);
    expect(calls, 3);
  });

  test('gives up after maxAttempts and on non-retryable errors', () async {
    var calls = 0;
    final failing = clientFor((req) async {
      calls++;
      return http.Response('boom', 503);
    }, maxAttempts: 2);
    await expectLater(failing.metadata('x'), throwsA(isA<ArchiveException>()));
    expect(calls, 2);

    calls = 0;
    final notFound = clientFor((req) async {
      calls++;
      return http.Response('no', 404);
    });
    await expectLater(notFound.metadata('x'), throwsA(isA<ArchiveException>()));
    expect(calls, 1);
  });

  test('metadata reads the private flag of restricted files', () async {
    final client = clientFor((req) async => http.Response(
        '{"metadata":{"title":"t"},"files":[{"name":"a.mp4","private":"true"},{"name":"b.mp4"}]}', 200));
    final files = (await client.metadata('x'))!.files;
    expect(files.map((f) => f.private), [true, false]);
  });

  test('connection errors are retried, then succeed', () async {
    var calls = 0;
    final client = clientFor((req) async {
      calls++;
      if (calls < 3) throw http.ClientException('reset');
      return http.Response('{}', 200);
    });
    expect(await client.metadata('x'), isNull);
    expect(calls, 3);
  });

  test('persistent connection errors end in ArchiveException', () async {
    final client = clientFor((req) async => throw http.ClientException('down'));
    await expectLater(client.metadata('x'), throwsA(isA<ArchiveException>()));
  });

  test('a request that never completes times out into ArchiveException', () async {
    final client = clientFor((req) => Completer<http.Response>().future,
        maxAttempts: 2, requestTimeout: const Duration(milliseconds: 50));
    await expectLater(client.metadata('x'), throwsA(isA<ArchiveException>()));
  });

  test('parseLength handles seconds and clock formats', () {
    expect(parseLength('1763.3'), 1763.3);
    expect(parseLength('00:22:05'), 1325);
    expect(parseLength('04:45'), 285);
    expect(parseLength(''), isNull);
    expect(parseLength(null), isNull);
    expect(parseLength('abc'), isNull);
  });
}
