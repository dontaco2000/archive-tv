import 'package:archive_tv_core/src/models.dart';
import 'package:archive_tv_core/src/query_builder.dart';
import 'package:test/test.dart';

void main() {
  const range = YearRange(1980, 2010);

  test('query source gets mediatype and year range', () {
    expect(
      buildQuery(const Source(query: 'subject:cartoon'), range: range),
      '(subject:cartoon) AND mediatype:movies AND date:[1980-01-01 TO 2010-12-31]',
    );
  });

  test('collection source', () {
    expect(
      buildQuery(const Source(collection: 'computerchronicles'), range: range),
      '(collection:computerchronicles) AND mediatype:movies AND date:[1980-01-01 TO 2010-12-31]',
    );
  });

  test('identifier source quotes each id', () {
    expect(
      buildQuery(const Source(identifiers: ['a-1', 'b_2']), range: range),
      '(identifier:("a-1" OR "b_2")) AND mediatype:movies AND date:[1980-01-01 TO 2010-12-31]',
    );
  });

  test('ignoreYear drops the date clause, no range drops it too', () {
    expect(buildQuery(const Source(query: 'x', ignoreYear: true), range: range),
        '(x) AND mediatype:movies');
    expect(buildQuery(const Source(query: 'x')), '(x) AND mediatype:movies');
  });

  test('minDownloads, audio mediatype and blocked collections', () {
    expect(
      buildQuery(
        const Source(query: 'x', minDownloads: 2000, mediatype: 'audio'),
        range: range,
        blockCollections: ['adultvhs', 'xxx'],
      ),
      '(x) AND mediatype:audio AND date:[1980-01-01 TO 2010-12-31] '
      'AND downloads:[2000 TO 1000000000] AND -collection:(adultvhs OR xxx)',
    );
  });
}
