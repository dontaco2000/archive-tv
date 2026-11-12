import 'package:archive_tv_core/src/config.dart';
import 'package:archive_tv_core/src/models.dart';
import 'package:test/test.dart';

const _good = '''
{
  "yearRange": [1980, 2010],
  "channels": [
    {"number": 2, "name": "Funnies", "genre": "Kids & Animation", "logo": "Logos/square/funnies.png",
     "sources": [{"query": "subject:(cartoon OR cartoons)"}]},
    {"number": 28, "name": "Simmer", "shortContent": "Recipes", "yearRange": [1960, 2010],
     "sources": [{"query": "subject:cooking"},
                 {"identifiers": ["yan-can-cook-kqed"], "ignoreYear": true}]},
    {"number": 33, "name": "Cumulus", "type": "weatherstar", "location": "auto"}
  ],
  "excludeIdentifiers": ["bad-item"],
  "blockCollections": ["adultvhs"]
}
''';

void expectError(String json, String text) {
  expect(
    () => parseChannelConfig(json),
    throwsA(isA<ConfigException>().having((e) => e.message, 'message', contains(text))),
  );
}

void main() {
  test('parses a valid config', () {
    final c = parseChannelConfig(_good);
    expect(c.yearRange, const YearRange(1980, 2010));
    expect(c.fallbackStart, 1960);
    expect(c.minContentSeconds, 7200);
    expect(c.channels.map((x) => x.number), [2, 28, 33]);
    expect(c.channel(2)!.name, 'Funnies');
    expect(c.channel(2)!.logo, 'Logos/square/funnies.png');
    expect(c.channel(28)!.yearRange, const YearRange(1960, 2010));
    expect(c.channel(28)!.shortContent, 'Recipes');
    expect(c.channel(2)!.shortContent, isNull);
    expect(c.channel(28)!.sources[1].ignoreYear, isTrue);
    expect(c.channel(28)!.sources[1].identifiers, ['yan-can-cook-kqed']);
    expect(c.channel(33)!.type, 'weatherstar');
    expect(c.channel(33)!.sources, isEmpty);
    expect(c.excludeIdentifiers, {'bad-item'});
    expect(c.blockCollections, ['adultvhs']);
    expect(c.channel(99), isNull);
  });

  test('a weatherstar channel may list music sources', () {
    final c = parseChannelConfig('{"channels":[{"number":33,"name":"Cumulus","type":"weatherstar",'
        '"sources":[{"identifiers":["jazz"],"mediatype":"audio","ignoreYear":true}]}]}');
    final s = c.channel(33)!.sources.single;
    expect([s.identifiers, s.mediatype, s.ignoreYear], [['jazz'], 'audio', true]);
  });

  test('a source may cap its entries with maxEntries', () {
    final c = parseChannelConfig('{"channels":[{"number":2,"name":"A","sources":[{"query":"x","maxEntries":250},{"query":"y"}]}]}');
    expect(c.channel(2)!.sources.map((s) => s.maxEntries), [250, null]);
  });

  test('applies defaults when optional settings are missing', () {
    final c = parseChannelConfig(
        '{"channels":[{"number":1,"name":"A","sources":[{"collection":"x"}]}]}');
    expect(c.yearRange, const YearRange(1980, 2010));
    expect(c.fallbackStart, 1960);
    expect(c.channels.single.sources.single.mediatype, 'movies');
  });

  test('rejects bad JSON and wrong shapes', () {
    expectError('{nope', 'not valid JSON');
    expectError('[]', 'must be a JSON object');
    expectError('{}', '"channels" must be a non-empty list');
    expectError('{"channels":[]}', 'non-empty list');
  });

  test('rejects bad channels', () {
    expectError('{"channels":[{"number":1,"name":"A","sources":[{"query":"x"}]},'
        '{"number":1,"name":"B","sources":[{"query":"x"}]}]}', 'used twice');
    expectError('{"channels":[{"number":0,"name":"A","sources":[{"query":"x"}]}]}', 'number');
    expectError('{"channels":[{"number":1,"name":" ","sources":[{"query":"x"}]}]}', 'needs a "name"');
    expectError('{"channels":[{"number":1,"name":"A"}]}', 'at least one source');
    expectError('{"channels":[{"number":1,"name":"A","type":"zzz"}]}', 'unknown type');
  });

  test('rejects bad sources and year ranges', () {
    expectError('{"channels":[{"number":1,"name":"A","sources":[{}]}]}', 'exactly one');
    expectError('{"channels":[{"number":1,"name":"A","sources":[{"query":"x","collection":"y"}]}]}',
        'exactly one');
    expectError('{"yearRange":[2010,1980],"channels":[{"number":1,"name":"A","sources":[{"query":"x"}]}]}',
        'starts after it ends');
    expectError('{"yearRange":"1980","channels":[{"number":1,"name":"A","sources":[{"query":"x"}]}]}',
        'two years');
  });

  test('wrong-typed values are ConfigException, not TypeError', () {
    expectError(
        '{"channels":[{"number":2,"name":"A","sources":[{"query":"x","ignoreYear":"true"}]}]}',
        'wrong type');
    expectError('{"channels":[{"number":2,"name":5,"sources":[{"query":"x"}]}]}', 'name');
    expectError(
        '{"channels":[{"number":2,"name":"A","genre":5,"sources":[{"query":"x"}]}]}', 'wrong type');
  });
}
