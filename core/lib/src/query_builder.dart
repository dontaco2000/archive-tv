import 'models.dart';

/// Builds the Archive (Lucene) search query for one [source].
///
/// [range] is the year range that applies to the channel (null = none).
/// A source with `ignoreYear` skips the range, because Archive's `date`
/// field is often missing or wrong for a few well-known shows.
String buildQuery(
  Source source, {
  YearRange? range,
  List<String> blockCollections = const [],
}) {
  final String core;
  if (source.query != null) {
    core = source.query!;
  } else if (source.collection != null) {
    core = 'collection:${source.collection}';
  } else {
    core = 'identifier:(${source.identifiers.map((i) => '"$i"').join(' OR ')})';
  }

  final parts = <String>['($core)', 'mediatype:${source.mediatype}'];
  if (range != null && !source.ignoreYear) {
    parts.add('date:[${range.start}-01-01 TO ${range.end}-12-31]');
  }
  if (source.minDownloads != null) {
    parts.add('downloads:[${source.minDownloads} TO 1000000000]');
  }
  if (blockCollections.isNotEmpty) {
    parts.add('-collection:(${blockCollections.join(' OR ')})');
  }
  return parts.join(' AND ');
}
