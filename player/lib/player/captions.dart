import 'dart:convert';

import 'package:archive_tv_core/archive_tv_core.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Runs one mpv command (`['set', 'sid', 'no']`, `['sub-add', url, ...]`). Tests pass a recorder.
typedef MpvCommand = Future<void> Function(List<String> args);

/// Caption size steps (menu and remote); 4 is the default.
const captionSizeMin = 1, captionSizeMax = 7, captionSizeDefault = 4;

/// Caption text height as a share of the 4:3 frame height: step 4 is about 5.8% (42 px in a 720 px
/// frame, over twice media_kit's default of about 18 px there), step 1 is 3.7%, step 7 is 7.9%.
double captionFraction(int size) => 0.03 + 0.007 * size.clamp(captionSizeMin, captionSizeMax);

/// What the captions are doing for the file on screen:
/// `off` (English item, CC off), `on` (CC on, a track is showing), `forced` (foreign item, English
/// subtitles forced on), `none` (CC on but the file has no captions), `missing` (foreign item without
/// any English subtitles: the player skips it).
typedef CaptionState = String;

/// One subtitle track from mpv's `track-list`.
class SubTrack {
  final int id;
  final String? lang;
  final String? title;

  /// Added with `sub-add` (a sidecar file), not part of the video file.
  final bool external;
  const SubTrack(this.id, {this.lang, this.title, this.external = false});
}

/// The subtitle tracks in mpv's `track-list` JSON.
List<SubTrack> parseSubTracks(String trackListJson) {
  try {
    final list = jsonDecode(trackListJson);
    if (list is! List) return const [];
    return [
      for (final t in list.whereType<Map>())
        if (t['type'] == 'sub' && t['id'] is int)
          SubTrack(t['id'] as int,
              lang: t['lang'] as String?, title: t['title'] as String?, external: t['external'] == true),
    ];
  } on FormatException {
    return const [];
  }
}

final _englishTitle = RegExp(r'\beng(lish)?\b', caseSensitive: false);

/// An English track: tagged en/eng(/en-US), or titled English. With [lenient] (an English item)
/// an untagged track counts too.
bool isEnglishTrack(SubTrack t, {bool lenient = false}) {
  final l = t.lang?.toLowerCase();
  if (l == 'en' || l == 'eng' || (l != null && l.startsWith('en-'))) return true;
  if (t.title != null && _englishTitle.hasMatch(t.title!)) return true;
  return lenient && (l == null || l.isEmpty || l == 'und');
}

/// Before every open: mpv must not pick subtitles by itself (a "default"-flagged track showed
/// captions on English shows like Caillou) nor load files next to the video.
Future<void> resetCaptions(MpvCommand mpv) async {
  await mpv(['set', 'sub-auto', 'no']);
  await mpv(['set', 'sid', 'no']);
}

/// After [e] opened: shows the caption it should have, given its subtitle [tracks] and the viewer's
/// CC switch. Foreign Archive items ([forceForeign]) always get English: the sidecar file first, else an
/// embedded English track. English items only when [captionsOn]: an embedded track first, else the sidecar.
Future<CaptionState> applyCaptions(MpvCommand mpv, Entry e, List<SubTrack> tracks,
    {required bool captionsOn, bool forceForeign = true}) async {
  final forced = forceForeign && e.foreign;
  if (!forced && !captionsOn) {
    await mpv(['set', 'sid', 'no']);
    return 'off';
  }
  final english = tracks.where((t) => isEnglishTrack(t, lenient: !forced));
  final embedded = english.where((t) => !t.external).firstOrNull;
  final added = english.where((t) => t.external).firstOrNull; // the sidecar, if CC was toggled before
  final Future<void> Function()? sidecar = e.subUrl == null
      ? null
      : added != null
          ? () => mpv(['set', 'sid', '${added.id}'])
          : () => mpv(['sub-add', e.subUrl!, 'select', 'English', 'en']);
  final Future<void> Function()? inFile = embedded == null ? null : () => mpv(['set', 'sid', '${embedded.id}']);
  // Foreign: the sidecar (made for viewers) first; CC on an English item: the file's own captions first.
  final pick = forced ? (sidecar ?? inFile) : (inFile ?? sidecar);
  if (pick == null) return forced ? 'missing' : 'none';
  await pick();
  return forced ? 'forced' : 'on';
}

/// How captions look: white text with a dark outline on a translucent box, at the bottom of the
/// 4:3 frame ([frameHeight] tall), sized by the viewer's [size] step.
SubtitleViewConfiguration captionStyle(double frameHeight, int size, {bool visible = true}) {
  final px = (frameHeight * captionFraction(size)).clamp(10.0, 200.0);
  final o = (px / 16).clamp(1.0, 4.0);
  return SubtitleViewConfiguration(
    visible: visible,
    textScaler: TextScaler.noScaling,
    padding: EdgeInsets.fromLTRB(frameHeight * 0.06, 0, frameHeight * 0.06, frameHeight * 0.05),
    style: TextStyle(
      fontSize: px,
      height: 1.25,
      color: Colors.white,
      fontWeight: FontWeight.w600,
      backgroundColor: const Color(0x99000000),
      shadows: [
        for (final (dx, dy) in [(-o, 0.0), (o, 0.0), (0.0, -o), (0.0, o), (-o, -o), (o, o), (-o, o), (o, -o)])
          Shadow(offset: Offset(dx, dy), color: Colors.black),
      ],
    ),
  );
}
