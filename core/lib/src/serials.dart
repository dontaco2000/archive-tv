import 'dart:convert';

import 'archive_client.dart';
import 'file_picker.dart';
import 'models.dart';

/// [show]'s episodes in air order, each titled like "Death Note S1E5". [metas] are its items in
/// [SerialShow.identifiers] order (null = item missing). Files are picked as for pools (one small
/// file per episode), then filtered by include/exclude and ordered:
/// - `episode` regex: files it doesn't match are dropped; 2 groups = season, episode; 1 group =
///   episode with the item's position as season. Sorted by item, season, episode; duplicates dropped.
/// - `order` list: exactly those files (by file name or `item/file` id), in that order, as S1E1...
///   (or labelled by the `episode` regex when one is given too: for items whose numbers repeat).
/// - neither: natural file-name order per item, numbered from 1, season = item position.
List<Entry> resolveEpisodes(SerialShow show, List<ItemMeta?> metas) {
  final found = <({int item, int season, int episode, Entry entry})>[];
  for (final (i, meta) in metas.indexed) {
    if (meta == null) continue;
    final files = [
      for (final e in pickEntries(meta))
        if ((show.include?.hasMatch(e.file) ?? true) && !(show.exclude?.hasMatch(e.file) ?? false)) e,
    ]..sort((a, b) => naturalCompare(a.file, b.file));
    for (final (pos, e) in files.indexed) {
      if (show.episode case final re?) {
        final m = re.firstMatch(e.file);
        final ep = int.tryParse(m?.group(m.groupCount) ?? '');
        if (m == null || ep == null) continue;
        final season = m.groupCount == 2 ? int.tryParse(m.group(1) ?? '') : i + 1;
        if (season == null) continue;
        found.add((item: i, season: season, episode: ep, entry: e));
      } else {
        found.add((item: i, season: i + 1, episode: pos + 1, entry: e));
      }
    }
  }

  if (show.order case final names?) {
    final byName = {for (final f in found) f.entry.file: f, for (final f in found) f.entry.id: f};
    return [
      for (final (pos, n) in names.indexed)
        if (byName[n] case final f?)
          f.entry.copyWith(
              title: show.episode == null ? '${show.title} S1E${pos + 1}' : '${show.title} S${f.season}E${f.episode}'),
    ];
  }

  found.sort((a, b) => a.item != b.item
      ? a.item - b.item
      : a.season != b.season
          ? a.season - b.season
          : a.episode != b.episode
              ? a.episode - b.episode
              : naturalCompare(a.entry.file, b.entry.file)); // duplicates: the first by name is kept
  final seen = <String>{};
  return [
    for (final f in found)
      if (seen.add('${f.item}/${f.season}/${f.episode}')) f.entry.copyWith(title: '${show.title} S${f.season}E${f.episode}'),
  ];
}

/// Episode lists for every serial slot of [channel]: `[slot][show]` -> episodes. A show with fewer
/// than [minEpisodes] playable episodes fails the gate: logged, and its list left empty (skipped).
/// Item metadata is fetched one at a time.
Future<List<List<List<Entry>>>> buildSerialEpisodes(
  Channel channel,
  ArchiveApi api, {
  int minEpisodes = 8,
  void Function(String)? log,
}) async {
  final metas = <String, ItemMeta?>{};
  final out = <List<List<Entry>>>[];
  for (final slot in channel.serials) {
    final shows = <List<Entry>>[];
    for (final show in slot.shows) {
      final items = <ItemMeta?>[];
      for (final id in show.identifiers) {
        try {
          items.add(metas.containsKey(id) ? metas[id] : metas[id] = await api.metadata(id));
        } on ArchiveException catch (e) {
          log?.call('${channel.name}: serial ${show.title}: skip $id: $e');
          items.add(null);
        }
      }
      final eps = resolveEpisodes(show, items);
      if (eps.length < minEpisodes) {
        log?.call('${channel.name}: serial ${show.title} has ${eps.length} playable episodes (< $minEpisodes), skipped');
      }
      shows.add(eps.length < minEpisodes ? const [] : eps);
    }
    out.add(shows);
  }
  return out;
}

/// Changes when anything that decides a channel's episode lists changes (not start/epoch/perDay),
/// so saved lists from an older config are rebuilt.
String serialsSignature(Channel c) => jsonEncode([
      for (final s in c.serials)
        [
          for (final sh in s.shows)
            [sh.title, sh.identifiers, sh.include?.pattern, sh.exclude?.pattern, sh.episode?.pattern, sh.order],
        ],
    ]);
