import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:test/test.dart';

/// Archive stand-in: [items] maps identifier -> (year, minutes of one video).
class FakeApi implements ArchiveApi {
  final Map<String, (int, int)> items;
  final List<String> queries = [];
  final Set<String> failing;
  final String? failQuery; // searches containing this text throw

  FakeApi(this.items, {this.failing = const {}, this.failQuery});

  @override
  Future<List<ItemSummary>> search(String query, {int rows = 100, int page = 1}) async {
    queries.add(query);
    if (failQuery != null && query.contains(failQuery!)) throw ArchiveException('search down');
    // Honour only the date clause, like the real thing would.
    final m = RegExp(r'date:\[(\d{4})-01-01 TO (\d{4})-12-31\]').firstMatch(query);
    return [
      for (final e in items.entries)
        if (m == null || (e.value.$1 >= int.parse(m.group(1)!) && e.value.$1 <= int.parse(m.group(2)!)))
          ItemSummary(e.key),
    ];
  }

  @override
  Future<ItemMeta?> metadata(String identifier) async {
    if (failing.contains(identifier)) throw ArchiveException('boom');
    final item = items[identifier];
    if (item == null) return null;
    return ItemMeta(identifier, title: identifier, files: [
      ArchiveFile('$identifier.mp4', format: 'h.264', length: item.$2 * 60.0),
    ]);
  }
}

ChannelConfig config({int minHours = 2, Set<String> exclude = const {}}) => ChannelConfig(
      yearRange: const YearRange(1980, 2010),
      fallbackStart: 1960,
      minContentSeconds: minHours * 3600,
      channels: const [],
      excludeIdentifiers: exclude,
      blockCollections: const ['adultvhs'],
    );

const channel = Channel(number: 5, name: 'Funnies', sources: [Source(query: 'subject:cartoon')]);

void main() {
  test('builds a pool from search + metadata and skips excluded ids', () async {
    final api = FakeApi({'a': (1990, 30), 'b': (1995, 30), 'c': (2001, 60)});
    final pool = await buildPool(channel, config(minHours: 1, exclude: {'b'}), api);
    expect(pool.map((e) => e.itemId), unorderedEquals(['a', 'c']));
    expect(api.queries.single, contains('-collection:(adultvhs)'));
  });

  test('thin channel widens to the fallback year and rebuilds', () async {
    final api = FakeApi({'new': (1990, 30), 'old': (1970, 120)});
    final pool = await buildPool(channel, config(), api);
    expect(pool.map((e) => e.itemId), unorderedEquals(['new', 'old']));
    expect(api.queries, hasLength(2));
    expect(api.queries.last, contains('1960-01-01 TO 2010-12-31'));
  });

  test('a channel that is big enough does not widen', () async {
    final api = FakeApi({'a': (1990, 180)});
    await buildPool(channel, config(), api);
    expect(api.queries, hasLength(1));
  });

  test('one failing item is skipped, the rest still build', () async {
    final logs = <String>[];
    final api = FakeApi({'a': (1990, 90), 'bad': (1990, 90)}, failing: {'bad'});
    final pool = await buildPool(channel, config(), api, log: logs.add);
    expect(pool.map((e) => e.itemId), ['a']);
    expect(logs.any((l) => l.contains('skip bad')), isTrue);
  });

  test('a failing source is skipped, the other source still builds the pool', () async {
    final logs = <String>[];
    const two = Channel(number: 5, name: 'Funnies', sources: [
      Source(query: 'subject:broken'),
      Source(query: 'subject:cartoon'),
    ]);
    final api = FakeApi({'a': (1990, 180)}, failQuery: 'broken');
    final pool = await buildPool(two, config(), api, log: logs.add);
    expect(pool.map((e) => e.itemId), ['a']);
    expect(logs.any((l) => l.contains('skip source')), isTrue);
  });

  test('weatherstar channels have no pool', () async {
    const wx = Channel(number: 1, name: 'Cumulus', type: 'weatherstar');
    expect(await buildPool(wx, config(), FakeApi({})), isEmpty);
  });
}
