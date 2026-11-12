import 'models.dart';
import 'scheduler.dart';
import 'title_cleaner.dart';

/// Items shorter than this are "short" for guide grouping.
const shortItem = Duration(minutes: 20);

/// A same-show run at least this long is a "`<Show>` Marathon"; also the size of a full short-content block.
const marathonMin = Duration(hours: 2);

/// A short-content block smaller than this at either end of a stretch joins its neighbour.
const _sliver = Duration(minutes: 30);

/// Short items lasting less than this in total (usually a filler cut short before a serial block)
/// join the block before them.
const _filler = Duration(minutes: 5);

final _marker = RegExp(
    r'[\s\-–:|,.#(]*(s[-\s.]?\d{1,2}[-\s.]?e[-\s.]?\d{1,3}|\bs\d{1,2}\s*[-–]\s*s\d{1,2}\b|\b\d{1,2}x\d{2,3}\b|\bepisode\s*\d+|\bep\.?\s*\d+\b|\bseason\s*\d+|\bpart\s*\d+\b|\bvol(ume)?\.?\s*\d+\b).*$',
    caseSensitive: false);
final _dashNumber = RegExp(r'\s+[-–#]\s*\d{1,4}\b.*$'); // "Show - 70", "Show - 05,04 - Title"

/// The show an item belongs to, for guide grouping: the cleaned title cut at the first
/// season/episode marker ("Camp Lazlo - S04E08 - Strange Trout" -> "Camp Lazlo",
/// "Death Note S1E5" -> "Death Note", "Boboboubo Boubobo - 70" -> "Boboboubo Boubobo").
/// A title that starts with a marker ("S5E04 Is There a Muppet...") falls back to the item id
/// ("thomas-and-friends-s01-s17" -> "Thomas And Friends", same key as "Thomas & Friends").
/// All-lower-case results are capitalised word by word ("cops-s-28-e-22" -> "Cops").
String showTitle(Entry e) {
  String cut(String s) => cleanTitle(s).replaceFirst(_marker, '').replaceFirst(_dashNumber, '').trim();
  var t = cut(e.title);
  if (t.isEmpty) t = cut(e.itemId);
  if (t != t.toLowerCase()) return t;
  // all lower case (file or item names like "cops-s-28-e-22"): "Cops"
  return t.split(RegExp(r'[\s_-]+')).map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
}

/// Case/punctuation-insensitive comparison key ("Thomas & Friends" == "thomas and friends").
String showKey(Entry e) =>
    showTitle(e).toLowerCase().replaceAll('&', 'and').replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// The guide's view of [slots] (consecutive, in time order). Display only: playback still uses
/// the real slots. Blocks are slots whose entry is the first item they cover, retitled:
/// - [shortContent] set (e.g. "Commercials"): the whole schedule becomes 2-hour blocks on even
///   clock hours, "More Commercials"; a block that has to be shorter is just "Commercials".
/// - otherwise 2+ consecutive items of the same show become one block: "`<Show>` Marathon" when it
///   lasts at least 2 hours, else "`<Show>`".
/// - other runs of 2+ consecutive short items (under 20 min) become "Shorts" blocks, cut like
///   short content ("More Shorts" / "Shorts").
/// - short items lasting under 5 minutes in total join the block before them.
/// - everything else stays one cell per item.
List<Slot> guideBlocks(List<Slot> slots, {String? shortContent}) {
  final out = <Slot>[];
  final shorts = <Slot>[];
  void flush() {
    if (shorts.isEmpty) return;
    if (out.isNotEmpty && shorts.last.end.difference(shorts.first.start) < _filler) {
      out.last = Slot(out.last.entry, out.last.start, shorts.last.end);
    } else if (shorts.length >= 2 || shortContent != null) {
      _cut(shorts, shortContent ?? 'Shorts', out);
    } else {
      out.add(shorts.single);
    }
    shorts.clear();
  }

  var i = 0;
  while (i < slots.length) {
    if (shortContent == null) {
      final k = showKey(slots[i].entry);
      var j = i + 1;
      while (j < slots.length && k.isNotEmpty && showKey(slots[j].entry) == k) {
        j++;
      }
      if (j - i >= 2) {
        flush();
        final first = slots[i], last = slots[j - 1];
        final show = showTitle(first.entry);
        final long = last.end.difference(first.start) >= marathonMin;
        out.add(Slot(first.entry.copyWith(title: long ? '$show Marathon' : show), first.start, last.end));
        i = j;
        continue;
      }
    }
    final s = slots[i++];
    if (shortContent != null || s.end.difference(s.start) < shortItem) {
      shorts.add(s);
    } else {
      flush();
      out.add(s);
    }
  }
  flush();
  return out;
}

DateTime _nextEvenHour(DateTime t) => DateTime(t.year, t.month, t.day, t.hour - t.hour % 2 + 2);

/// Cuts the stretch [run] into blocks ending on even clock hours. Slivers under 30 min at either end
/// join the neighbouring block. Blocks of 2 hours or more are "More [label]", shorter ones "[label]".
void _cut(List<Slot> run, String label, List<Slot> out) {
  final end = run.last.end;
  var t = run.first.start;
  while (t.isBefore(end)) {
    var b = _nextEvenHour(t);
    if (b.difference(t) < _sliver && b.isBefore(end)) b = _nextEvenHour(b);
    if (!b.isBefore(end) || end.difference(b) < _sliver) b = end;
    final at = slotAt(run, t) ?? run.first;
    out.add(Slot(at.entry.copyWith(title: b.difference(t) >= marathonMin ? 'More $label' : label), t, b));
    t = b;
  }
}
